defmodule Abyssalwatch.Fittings.ESI.Client do
  @moduledoc """
  ESI API client for ship fittings and related data.

  Handles:
  - Fetching character fittings
  - Creating new fittings
  - Deleting fittings
  - Fetching ship/module type information

  All authenticated endpoints require a valid access token.
  Token refresh is handled automatically when possible.
  """

  require Logger

  alias Abyssalwatch.Accounts.EVEAuth

  @base_url "https://esi.evetech.net/latest"
  @user_agent "AbyssalWatch (https://github.com/abyssalwatch)"

  @doc """
  Fetch all fittings for a character.

  Returns a list of fitting maps with structure:
  - fitting_id: integer
  - name: string
  - description: string
  - ship_type_id: integer
  - items: list of {type_id, flag, quantity}
  """
  @spec get_fittings(integer(), String.t()) :: {:ok, list(map())} | {:error, term()}
  def get_fittings(character_id, access_token) do
    url = "#{@base_url}/characters/#{character_id}/fittings/"

    case authenticated_request(:get, url, access_token) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, Enum.map(body, &parse_fitting/1)}

      {:ok, %{status: 200, body: body}} ->
        # Handle case where body is a single fitting or other structure
        {:ok, [parse_fitting(body)]}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("ESI get_fittings failed: status=#{status}, body=#{inspect(body)}")
        {:error, "Failed to fetch fittings: #{status}"}

      {:error, reason} ->
        Logger.error("ESI get_fittings error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Create a new fitting for a character.

  Fitting should have:
  - name: string
  - description: string (optional)
  - ship_type_id: integer
  - items: list of %{type_id: int, flag: string, quantity: int}

  Returns {:ok, fitting_id} on success.
  """
  @spec create_fitting(integer(), map(), String.t()) :: {:ok, integer()} | {:error, term()}
  def create_fitting(character_id, fitting, access_token) do
    url = "#{@base_url}/characters/#{character_id}/fittings/"

    body = %{
      name: fitting.name,
      description: fitting[:description] || "",
      ship_type_id: fitting.ship_type_id,
      items: format_items_for_esi(fitting.items)
    }

    case authenticated_request(:post, url, access_token, body) do
      {:ok, %{status: 201, body: %{"fitting_id" => fitting_id}}} ->
        {:ok, fitting_id}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("ESI create_fitting failed: status=#{status}, body=#{inspect(body)}")
        {:error, "Failed to create fitting: #{status}"}

      {:error, reason} ->
        Logger.error("ESI create_fitting error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Delete a fitting from a character.
  """
  @spec delete_fitting(integer(), integer(), String.t()) :: :ok | {:error, term()}
  def delete_fitting(character_id, fitting_id, access_token) do
    url = "#{@base_url}/characters/#{character_id}/fittings/#{fitting_id}/"

    case authenticated_request(:delete, url, access_token) do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("ESI delete_fitting failed: status=#{status}, body=#{inspect(body)}")
        {:error, "Failed to delete fitting: #{status}"}

      {:error, reason} ->
        Logger.error("ESI delete_fitting error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get information about a ship or module type.
  This endpoint does not require authentication.
  """
  @spec get_type(integer()) :: {:ok, map()} | {:error, term()}
  def get_type(type_id) do
    url = "#{@base_url}/universe/types/#{type_id}/"

    case unauthenticated_request(:get, url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_type_info(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("ESI get_type failed: status=#{status}, body=#{inspect(body)}")
        {:error, "Failed to get type info: #{status}"}

      {:error, reason} ->
        Logger.error("ESI get_type error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get multiple type infos in batch.
  Uses POST endpoint for efficiency with many IDs.
  """
  @spec get_types(list(integer())) :: {:ok, list(map())} | {:error, term()}
  def get_types([]), do: {:ok, []}

  def get_types(type_ids) when is_list(type_ids) do
    url = "#{@base_url}/universe/names/"

    case unauthenticated_request(:post, url, type_ids) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, Enum.map(body, &parse_name_info/1)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("ESI get_types failed: status=#{status}, body=#{inspect(body)}")
        {:error, "Failed to get type names: #{status}"}

      {:error, reason} ->
        Logger.error("ESI get_types error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get character information.
  This endpoint does not require authentication.
  """
  @spec get_character(integer()) :: {:ok, map()} | {:error, term()}
  def get_character(character_id) do
    url = "#{@base_url}/characters/#{character_id}/"

    case unauthenticated_request(:get, url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           character_id: character_id,
           name: body["name"],
           corporation_id: body["corporation_id"],
           alliance_id: body["alliance_id"],
           birthday: body["birthday"],
           security_status: body["security_status"]
         }}

      {:ok, %{status: status}} ->
        {:error, "Failed to get character: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Refresh a user's access token if needed and return a valid token.
  """
  @spec ensure_valid_token(Abyssalwatch.Accounts.User.t()) ::
          {:ok, String.t(), Abyssalwatch.Accounts.User.t()} | {:error, term()}
  def ensure_valid_token(user) do
    if token_needs_refresh?(user) do
      case EVEAuth.refresh_token(user.refresh_token) do
        {:ok, token_response} ->
          expires_at =
            DateTime.utc_now()
            |> DateTime.add(token_response.expires_in, :second)

          # Update user with new tokens
          case Ash.update(
                 user,
                 %{
                   access_token: token_response.access_token,
                   refresh_token: token_response.refresh_token,
                   token_expires_at: expires_at
                 },
                 action: :refresh_tokens
               ) do
            {:ok, updated_user} ->
              {:ok, token_response.access_token, updated_user}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, user.access_token, user}
    end
  end

  # Private functions

  defp authenticated_request(method, url, access_token, body \\ nil) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"accept", "application/json"},
      {"user-agent", @user_agent}
    ]

    request(method, url, headers, body)
  end

  defp unauthenticated_request(method, url, body \\ nil) do
    headers = [
      {"accept", "application/json"},
      {"user-agent", @user_agent}
    ]

    request(method, url, headers, body)
  end

  defp request(:get, url, headers, _body) do
    Req.get(url, headers: headers)
  end

  defp request(:post, url, headers, body) do
    Req.post(url, headers: headers, json: body)
  end

  defp request(:delete, url, headers, _body) do
    Req.delete(url, headers: headers)
  end

  defp parse_fitting(fitting) do
    %{
      fitting_id: fitting["fitting_id"],
      name: fitting["name"],
      description: fitting["description"] || "",
      ship_type_id: fitting["ship_type_id"],
      items: Enum.map(fitting["items"] || [], &parse_fitting_item/1)
    }
  end

  defp parse_fitting_item(item) do
    %{
      type_id: item["type_id"],
      flag: item["flag"],
      quantity: item["quantity"]
    }
  end

  defp format_items_for_esi(items) when is_list(items) do
    Enum.map(items, fn item ->
      %{
        "type_id" => item[:type_id] || item["type_id"],
        "flag" => item[:flag] || item["flag"],
        "quantity" => item[:quantity] || item["quantity"]
      }
    end)
  end

  defp format_items_for_esi(_), do: []

  defp parse_type_info(body) do
    %{
      type_id: body["type_id"],
      name: body["name"],
      description: body["description"],
      group_id: body["group_id"],
      market_group_id: body["market_group_id"],
      published: body["published"],
      dogma_attributes: body["dogma_attributes"] || [],
      dogma_effects: body["dogma_effects"] || []
    }
  end

  defp parse_name_info(body) do
    %{
      id: body["id"],
      name: body["name"],
      category: body["category"]
    }
  end

  defp token_needs_refresh?(user) do
    case user.token_expires_at do
      nil ->
        true

      expires_at ->
        # Refresh if expiring within 5 minutes
        threshold = DateTime.add(DateTime.utc_now(), 5, :minute)
        DateTime.compare(expires_at, threshold) == :lt
    end
  end
end
