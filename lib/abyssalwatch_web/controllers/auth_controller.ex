defmodule AbyssalwatchWeb.AuthController do
  @moduledoc """
  Handles EVE SSO OAuth2 authentication callbacks and logout.

  OAuth2 Flow:
  1. User clicks "Login with EVE Online" -> redirected to EVE SSO
  2. User authenticates and grants permissions
  3. EVE SSO redirects to /auth/eve/callback with authorization code
  4. We exchange the code for access/refresh tokens
  5. Verify token to get character info
  6. Create/update user and log them in
  """
  use AbyssalwatchWeb, :controller

  require Logger

  alias Abyssalwatch.Accounts.EVEAuth
  alias Abyssalwatch.Accounts.User

  @doc """
  Handle the EVE SSO OAuth2 callback.

  Receives:
  - code: The authorization code to exchange for tokens
  - state: CSRF protection token (should match what we sent)

  On success: Creates/updates user and redirects to dashboard
  On failure: Redirects to sign-in with error message
  """
  def eve_callback(conn, %{"code" => code, "state" => _state}) do
    # TODO: Verify state matches session state for CSRF protection

    with {:ok, token_response} <- EVEAuth.exchange_code(code),
         {:ok, character_info} <- EVEAuth.verify_token(token_response.access_token),
         {:ok, user} <- create_or_update_user(token_response, character_info) do
      # Log the user in
      conn
      |> put_session(:user_id, user.id)
      |> put_session(:character_id, user.character_id)
      |> configure_session(renew: true)
      |> put_flash(:info, "Welcome, #{user.character_name}!")
      |> redirect(to: ~p"/dashboard")
    else
      {:error, reason} ->
        Logger.error("EVE SSO authentication failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/sign-in")
    end
  end

  def eve_callback(conn, %{"error" => error, "error_description" => description}) do
    Logger.warning("EVE SSO error: #{error} - #{description}")

    conn
    |> put_flash(:error, "EVE SSO error: #{description}")
    |> redirect(to: ~p"/sign-in")
  end

  def eve_callback(conn, _params) do
    conn
    |> put_flash(:error, "Invalid callback parameters")
    |> redirect(to: ~p"/sign-in")
  end

  @doc """
  Legacy callback handler for token-based auth (kept for compatibility).
  """
  def callback(conn, %{"token" => token}) do
    conn
    |> put_session(:user_token, token)
    |> configure_session(renew: true)
    |> put_flash(:info, "Successfully signed in!")
    |> redirect(to: ~p"/dashboard")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Authentication failed")
    |> redirect(to: ~p"/sign-in")
  end

  @doc """
  Log out the current user.
  """
  def logout(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, "You have been logged out.")
    |> redirect(to: ~p"/")
  end

  # Private functions

  defp create_or_update_user(token_response, character_info) do
    # Calculate token expiration
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(token_response.expires_in || 1200, :second)

    attrs = %{
      character_id: character_info.character_id,
      character_name: character_info.character_name,
      character_owner_hash: character_info.owner_hash,
      access_token: token_response.access_token,
      refresh_token: token_response.refresh_token,
      token_expires_at: expires_at
    }

    # Use Ash to create or update the user
    case Ash.create(User, attrs, action: :from_eve_sso) do
      {:ok, user} ->
        {:ok, user}

      {:error, error} ->
        Logger.error("Failed to create/update user: #{inspect(error)}")
        {:error, "Failed to create user account"}
    end
  end
end
