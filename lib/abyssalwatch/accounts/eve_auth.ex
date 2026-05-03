defmodule Abyssalwatch.Accounts.EVEAuth do
  @moduledoc """
  EVE SSO OAuth2 implementation - Primary authentication for AbyssalWatch.

  Users authenticate with their EVE Online account, providing:
  - Character identity (name, ID, portrait)
  - Access to ESI endpoints (fittings, etc.)
  - No separate password management needed

  ## OAuth2 Flow
  1. User clicks "Login with EVE Online"
  2. Redirect to EVE SSO authorize URL
  3. User logs in and grants permissions
  4. EVE SSO redirects back with authorization code
  5. Exchange code for access/refresh tokens
  6. Verify token to get character info
  7. Create/update user record

  ## Required Scopes
  - publicData: Basic character info
  - esi-fittings.read_fittings.v1: Read character fittings
  - esi-fittings.write_fittings.v1: Save fittings to character
  """

  require Logger

  @authorize_url "https://login.eveonline.com/v2/oauth/authorize"
  @token_url "https://login.eveonline.com/v2/oauth/token"
  # JWKS URL for JWT signature verification (can be used for enhanced security)
  # @jwks_url "https://login.eveonline.com/oauth/jwks"

  # Scopes for authentication and ESI access
  @scopes [
    "publicData",
    "esi-fittings.read_fittings.v1",
    "esi-fittings.write_fittings.v1"
  ]

  @doc """
  Generate the EVE SSO authorization URL.

  The state parameter should be a random string stored in the session
  to prevent CSRF attacks.
  """
  @spec authorize_url(String.t()) :: String.t()
  def authorize_url(state) do
    params = %{
      response_type: "code",
      redirect_uri: callback_url(),
      client_id: client_id(),
      scope: Enum.join(@scopes, " "),
      state: state
    }

    "#{@authorize_url}?#{URI.encode_query(params)}"
  end

  @doc """
  Exchange an authorization code for access and refresh tokens.

  Returns {:ok, token_response} or {:error, reason}.
  """
  @spec exchange_code(String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_code(code) do
    body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        code: code
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"authorization", "Basic #{base64_credentials()}"},
      {"host", "login.eveonline.com"}
    ]

    case Req.post(@token_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_token_response(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("EVE SSO token exchange failed: status=#{status}, body=#{inspect(body)}")
        {:error, "Token exchange failed with status #{status}"}

      {:error, reason} ->
        Logger.error("EVE SSO token exchange error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Refresh an expired access token using the refresh token.

  Returns {:ok, token_response} or {:error, reason}.
  """
  @spec refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_token(refresh_token) do
    body =
      URI.encode_query(%{
        grant_type: "refresh_token",
        refresh_token: refresh_token
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"authorization", "Basic #{base64_credentials()}"},
      {"host", "login.eveonline.com"}
    ]

    case Req.post(@token_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_token_response(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("EVE SSO token refresh failed: status=#{status}, body=#{inspect(body)}")
        {:error, "Token refresh failed with status #{status}"}

      {:error, reason} ->
        Logger.error("EVE SSO token refresh error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Verify and decode the JWT access token to get character information.

  EVE SSO v2 returns a JWT token that contains character info directly.
  Returns character_id, character_name, and scopes.
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_token(access_token) do
    # EVE SSO v2 uses JWT tokens. We can decode the payload to get character info.
    # For production, you should verify the JWT signature using JWKS.
    # For simplicity, we'll decode and trust the payload since we just exchanged it.
    case decode_jwt(access_token) do
      {:ok, claims} ->
        # Extract character info from JWT claims
        # The "sub" claim contains "CHARACTER:EVE:<character_id>"
        character_id = extract_character_id(claims["sub"])
        character_name = claims["name"]

        scopes =
          case claims["scp"] do
            list when is_list(list) -> list
            str when is_binary(str) -> String.split(str, " ", trim: true)
            _ -> []
          end

        expires_at = DateTime.from_unix!(claims["exp"])

        {:ok,
         %{
           character_id: character_id,
           character_name: character_name,
           scopes: scopes,
           expires_at: expires_at,
           owner_hash: claims["owner"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate the character portrait URL.
  """
  @spec portrait_url(integer(), integer()) :: String.t()
  def portrait_url(character_id, size \\ 128) do
    "https://images.evetech.net/characters/#{character_id}/portrait?size=#{size}"
  end

  @doc """
  Generate a random state string for CSRF protection.
  """
  @spec generate_state() :: String.t()
  def generate_state do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  # Private functions

  defp client_id do
    Application.get_env(:abyssalwatch, :eve_sso)[:client_id] ||
      raise "EVE_CLIENT_ID not configured"
  end

  defp client_secret do
    Application.get_env(:abyssalwatch, :eve_sso)[:client_secret] ||
      raise "EVE_CLIENT_SECRET not configured"
  end

  defp callback_url do
    Application.get_env(:abyssalwatch, :eve_sso)[:callback_url] ||
      "http://localhost:4000/auth/eve/callback"
  end

  defp base64_credentials do
    Base.encode64("#{client_id()}:#{client_secret()}")
  end

  defp parse_token_response(body) do
    %{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      expires_in: body["expires_in"],
      token_type: body["token_type"]
    }
  end

  defp decode_jwt(token) do
    # JWT format: header.payload.signature
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            {:ok, Jason.decode!(json)}

          :error ->
            {:error, "Invalid JWT payload encoding"}
        end

      _ ->
        {:error, "Invalid JWT format"}
    end
  end

  defp extract_character_id(sub) when is_binary(sub) do
    # Format: "CHARACTER:EVE:<character_id>"
    case String.split(sub, ":") do
      ["CHARACTER", "EVE", id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp extract_character_id(_), do: nil
end
