defmodule Abyssalwatch.Market.Mutamarket.Client do
  @moduledoc """
  HTTP client for Mutamarket.com API.
  Handles rate limiting, caching, and error handling.
  """

  alias Abyssalwatch.Market.Mutamarket.{RateLimiter, Cache}

  @base_url "https://mutamarket.com/api"
  @cache_ttl :timer.hours(24)

  @doc """
  Search for modules by type ID.

  ## Options
    * `:use_cache` - Whether to use cached results (default: true)
    * `:cache_ttl` - Cache TTL in milliseconds (default: 24 hours)
  """
  def search_modules(type_id, opts \\ []) do
    use_cache = Keyword.get(opts, :use_cache, true)
    cache_ttl = Keyword.get(opts, :cache_ttl, @cache_ttl)
    cache_key = {:modules_by_type, type_id}

    if use_cache do
      Cache.fetch(cache_key, cache_ttl, fn ->
        do_search_modules(type_id)
      end)
      |> case do
        {:ok, modules, _source} -> {:ok, modules}
        error -> error
      end
    else
      do_search_modules(type_id)
    end
  end

  @doc """
  Get a specific module by ID.
  """
  def get_module(module_id, opts \\ []) do
    use_cache = Keyword.get(opts, :use_cache, true)
    cache_ttl = Keyword.get(opts, :cache_ttl, @cache_ttl)
    cache_key = {:module, module_id}

    if use_cache do
      Cache.fetch(cache_key, cache_ttl, fn ->
        do_get_module(module_id)
      end)
      |> case do
        {:ok, module, _source} -> {:ok, module}
        error -> error
      end
    else
      do_get_module(module_id)
    end
  end

  @doc """
  Get all available module types.
  """
  def get_module_types(opts \\ []) do
    use_cache = Keyword.get(opts, :use_cache, true)
    cache_ttl = Keyword.get(opts, :cache_ttl, @cache_ttl)
    cache_key = :module_types

    if use_cache do
      Cache.fetch(cache_key, cache_ttl, fn ->
        do_get_module_types()
      end)
      |> case do
        {:ok, types, _source} -> {:ok, types}
        error -> error
      end
    else
      do_get_module_types()
    end
  end

  # Private implementation functions

  defp do_search_modules(type_id) do
    with :ok <- RateLimiter.acquire_blocking(),
         {:ok, response} <- make_request("/modules/type/#{type_id}") do
      {:ok, parse_modules(response.body)}
    end
  end

  defp do_get_module(module_id) do
    with :ok <- RateLimiter.acquire_blocking(),
         {:ok, response} <- make_request("/modules/#{module_id}") do
      {:ok, parse_module(response.body)}
    end
  end

  defp do_get_module_types do
    with :ok <- RateLimiter.acquire_blocking(),
         {:ok, response} <- make_request("/types") do
      {:ok, response.body}
    end
  end

  defp make_request(path) do
    url = @base_url <> path

    case Req.get(url,
           headers: [
             {"accept", "application/json"},
             {"user-agent", "AbyssalWatch/1.0"}
           ],
           retry: :transient,
           max_retries: 3,
           retry_delay: &retry_delay/1,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200} = response} ->
        {:ok, response}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_delay(attempt) do
    # Exponential backoff: 1s, 2s, 4s, capped at 30s
    min(30_000, 1_000 * :math.pow(2, attempt)) |> round()
  end

  defp parse_modules(body) when is_list(body) do
    Enum.map(body, &parse_module/1)
  end

  defp parse_modules(_), do: []

  defp parse_module(data) when is_map(data) do
    # Handle nested structure from Mutamarket API
    type_info = data["type"] || %{}
    contract_info = data["contract"]
    source_type_info = data["source_type"] || %{}
    public_asset_info = data["public_asset"] || %{}

    # Get price from contract first, then public_asset, then estimated_value
    price =
      cond do
        contract_info && contract_info["price"] ->
          parse_price(contract_info["price"])

        public_asset_info["price"] && public_asset_info["price"] > 0 ->
          parse_price(public_asset_info["price"])

        data["estimated_value"] ->
          parse_price(data["estimated_value"])

        true ->
          Decimal.new(0)
      end

    issuer_info =
      if contract_info do
        contract_info["issuer"] || %{}
      else
        public_asset_info["owner"] || %{}
      end

    %{
      external_id: to_string(data["id"] || ""),
      name: type_info["name"] || data["name"] || "Unknown Module",
      type_id: type_info["id"] || data["type_id"],
      type_name: type_info["name"] || data["type_name"],
      attributes:
        parse_attributes(data["mutated_attributes"] || data["attributes"] || data["stats"] || %{}),
      price: price,
      contract_id: to_string((contract_info && contract_info["id"]) || data["contract_id"] || ""),
      seller_name: issuer_info["name"] || data["seller_name"] || data["seller"] || "",
      location: data["location"] || data["station_name"] || "",
      # Base module info
      source_type_id: source_type_info["id"],
      source_type_name: source_type_info["name"],
      source_meta_group: source_type_info["meta_group"],
      # Mutaplasmid info
      mutaplasmid: data["mutaplasmid"],
      estimated_value: data["estimated_value"],
      # Is it on a contract?
      has_contract: not is_nil(contract_info)
    }
  end

  defp parse_module(_), do: nil

  defp parse_attributes(attrs) when is_map(attrs), do: attrs

  defp parse_attributes(attrs) when is_list(attrs) do
    Enum.reduce(attrs, %{}, fn attr, acc ->
      case attr do
        # Mutamarket format: mutated_attributes array with base_value
        %{"display_name" => display_name, "value" => value} = full_attr ->
          key = display_name || full_attr["name"]
          unit = get_in(full_attr, ["unit", "display_name"])

          attr_data = %{
            "value" => value,
            "base_value" => full_attr["base_value"],
            "unit" => unit,
            "is_derived" => full_attr["is_derived"]
          }

          Map.put(acc, key, attr_data)

        %{"name" => name, "value" => value} = full_attr ->
          attr_data = %{
            "value" => value,
            "base_value" => full_attr["base_value"],
            "unit" => get_in(full_attr, ["unit", "display_name"]),
            "is_derived" => full_attr["is_derived"]
          }

          Map.put(acc, name, attr_data)

        %{"attribute_id" => id, "value" => value} = full_attr ->
          attr_data = %{
            "value" => value,
            "base_value" => full_attr["base_value"],
            "unit" => nil,
            "is_derived" => nil
          }

          Map.put(acc, to_string(id), attr_data)

        _ ->
          acc
      end
    end)
  end

  defp parse_attributes(_), do: %{}

  defp parse_price(nil), do: Decimal.new(0)

  defp parse_price(price) when is_binary(price) do
    case Decimal.parse(price) do
      {decimal, _} -> decimal
      :error -> Decimal.new(0)
    end
  end

  defp parse_price(price) when is_number(price) do
    Decimal.new(round(price))
  end

  defp parse_price(_), do: Decimal.new(0)
end
