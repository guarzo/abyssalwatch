defmodule Abyssalwatch.Watchlists.Matcher do
  @moduledoc """
  Matches abyssal modules against watchlist criteria.

  Evaluates modules based on:
  - Important attributes: must meet or exceed minimum values
  - Unimportant attributes: must not exceed maximum values
  - Price threshold: must be at or below the limit
  - Minimum score: must meet or exceed the threshold
  """

  alias Abyssalwatch.Watchlists.Watchlist

  @type match_result :: %{
          module: map(),
          watchlist: Watchlist.t(),
          matched_at: DateTime.t(),
          match_details: match_details()
        }

  @type match_details :: %{
          important_attrs: %{String.t() => %{required: number(), actual: number()}},
          unimportant_attrs: %{String.t() => %{max_allowed: number(), actual: number()}},
          price_check: %{threshold: Decimal.t() | nil, actual: Decimal.t()},
          score_check: %{threshold: float() | nil, actual: float()}
        }

  @doc """
  Find all modules that match the given watchlist criteria.

  Returns a list of match results containing the module and match details.
  """
  @spec find_matches([map()], Watchlist.t()) :: [match_result()]
  def find_matches(modules, %Watchlist{} = watchlist) when is_list(modules) do
    modules
    |> Enum.filter(&matches_criteria?(&1, watchlist))
    |> Enum.map(&build_match_result(&1, watchlist))
  end

  @doc """
  Check if a single module matches the watchlist criteria.
  """
  @spec matches_criteria?(map(), Watchlist.t()) :: boolean()
  def matches_criteria?(module, %Watchlist{} = watchlist) do
    matches_price?(module, watchlist) and
      matches_score?(module, watchlist) and
      matches_important_attrs?(module, watchlist) and
      not_exceeds_unimportant?(module, watchlist)
  end

  @doc """
  Build detailed match information for a module that matches the watchlist.
  """
  @spec build_match_result(map(), Watchlist.t()) :: match_result()
  def build_match_result(module, %Watchlist{} = watchlist) do
    %{
      module: module,
      watchlist: watchlist,
      matched_at: DateTime.utc_now(),
      match_details: build_match_details(module, watchlist)
    }
  end

  # Price matching
  defp matches_price?(_module, %Watchlist{price_threshold: nil}), do: true

  defp matches_price?(module, %Watchlist{price_threshold: threshold}) do
    module_price = get_module_price(module)
    Decimal.compare(module_price, threshold) != :gt
  end

  # Score matching
  defp matches_score?(_module, %Watchlist{min_score: nil}), do: true

  defp matches_score?(module, %Watchlist{min_score: min_score}) do
    module_score = get_module_score(module)
    module_score >= min_score
  end

  # Important attributes: module value must be >= watchlist minimum
  defp matches_important_attrs?(_module, %Watchlist{important_attributes: attrs})
       when map_size(attrs) == 0,
       do: true

  defp matches_important_attrs?(module, %Watchlist{important_attributes: attrs}) do
    Enum.all?(attrs, fn {attr_name, min_value} ->
      case get_attribute(module, attr_name) do
        nil -> false
        value -> compare_attribute_value(value, min_value, :gte)
      end
    end)
  end

  # Unimportant attributes: module value must be <= watchlist maximum
  defp not_exceeds_unimportant?(_module, %Watchlist{unimportant_attributes: attrs})
       when map_size(attrs) == 0,
       do: true

  defp not_exceeds_unimportant?(module, %Watchlist{unimportant_attributes: attrs}) do
    Enum.all?(attrs, fn {attr_name, max_value} ->
      case get_attribute(module, attr_name) do
        # If the module doesn't have this attribute, it passes
        nil -> true
        value -> compare_attribute_value(value, max_value, :lte)
      end
    end)
  end

  # Helper functions
  defp get_module_price(%{price: price}) when not is_nil(price), do: price
  defp get_module_price(_), do: Decimal.new(0)

  defp get_module_score(%{score: score}) when is_number(score), do: score
  defp get_module_score(_), do: 0.0

  defp get_attribute(%{attributes: attrs}, attr_name) when is_map(attrs) do
    # Try string key first, then atom
    Map.get(attrs, attr_name) || Map.get(attrs, String.to_atom(attr_name))
  end

  defp get_attribute(_, _), do: nil

  defp compare_attribute_value(actual, threshold, :gte) do
    to_float(actual) >= to_float(threshold)
  end

  defp compare_attribute_value(actual, threshold, :lte) do
    to_float(actual) <= to_float(threshold)
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  # Build detailed match information for reporting
  defp build_match_details(module, %Watchlist{} = watchlist) do
    %{
      important_attrs: build_important_attrs_details(module, watchlist.important_attributes),
      unimportant_attrs:
        build_unimportant_attrs_details(module, watchlist.unimportant_attributes),
      price_check: %{
        threshold: watchlist.price_threshold,
        actual: get_module_price(module)
      },
      score_check: %{
        threshold: watchlist.min_score,
        actual: get_module_score(module)
      }
    }
  end

  defp build_important_attrs_details(module, attrs) when is_map(attrs) do
    Enum.into(attrs, %{}, fn {attr_name, min_value} ->
      {attr_name,
       %{
         required: min_value,
         actual: get_attribute(module, attr_name)
       }}
    end)
  end

  defp build_important_attrs_details(_, _), do: %{}

  defp build_unimportant_attrs_details(module, attrs) when is_map(attrs) do
    Enum.into(attrs, %{}, fn {attr_name, max_value} ->
      {attr_name,
       %{
         max_allowed: max_value,
         actual: get_attribute(module, attr_name)
       }}
    end)
  end

  defp build_unimportant_attrs_details(_, _), do: %{}
end
