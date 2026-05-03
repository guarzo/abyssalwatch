defmodule AbyssalwatchWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug that loads the current user from session.

  Supports two authentication methods:
  1. EVE SSO (Phase 4): User ID stored directly in session
  2. Legacy AshAuthentication: Token-based authentication

  The plug tries EVE SSO first, falling back to legacy token auth.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Abyssalwatch.Accounts.User

  @doc """
  Fetch the current user from session and assign to connection.

  Checks in order:
  1. Session user_id (EVE SSO authentication)
  2. Session user_token (Legacy AshAuthentication)
  """
  def fetch_current_user(conn, _opts) do
    cond do
      # EVE SSO: user_id stored directly in session
      user_id = get_session(conn, :user_id) ->
        fetch_user_by_id(conn, user_id)

      # Legacy: AshAuthentication token
      token = get_session(conn, :user_token) ->
        fetch_user_by_token(conn, token)

      true ->
        assign(conn, :current_user, nil)
    end
  end

  @doc """
  Require the user to be authenticated.

  If no user is logged in, redirect to sign in page.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: "/sign-in")
      |> halt()
    end
  end

  @doc """
  Redirect authenticated users away from auth pages.

  Used for sign in/sign up pages to redirect already logged in users.
  """
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: "/watch")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Log out the user by clearing the session.
  """
  def log_out_user(conn) do
    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> redirect(to: "/")
  end

  # Private functions

  defp fetch_user_by_id(conn, user_id) do
    case Ash.get(User, user_id) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      {:error, _} ->
        conn
        |> delete_session(:user_id)
        |> delete_session(:character_id)
        |> assign(:current_user, nil)
    end
  end

  defp fetch_user_by_token(conn, token) do
    # Legacy AshAuthentication token handling
    case AshAuthentication.subject_to_user(token, User, tenant: nil) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      _ ->
        conn
        |> delete_session(:user_token)
        |> assign(:current_user, nil)
    end
  end
end
