defmodule AbyssalwatchWeb.LiveAuth do
  @moduledoc """
  LiveView authentication hooks.

  Provides on_mount callbacks to load the current user into LiveView assigns.

  ## Available hooks:

  - `:default` - Assigns the current user from session to socket
  - `:require_authenticated` - Requires authentication, redirects if not logged in
  - `:redirect_if_authenticated` - Redirects authenticated users (for auth pages)
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias Abyssalwatch.Accounts.User

  @doc """
  Mount callback that handles authentication based on the hook type.
  """
  def on_mount(hook, params, session, socket)

  def on_mount(:default, _params, session, socket) do
    socket = assign_current_user(socket, session)
    {:cont, socket}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: "/sign-in")

      {:halt, socket}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      socket =
        socket
        |> redirect(to: "/dashboard")

      {:halt, socket}
    else
      {:cont, socket}
    end
  end

  defp assign_current_user(socket, session) do
    case session["user_token"] do
      nil ->
        assign(socket, :current_user, nil)

      token ->
        case AshAuthentication.subject_to_user(token, User, tenant: nil) do
          {:ok, user} ->
            assign(socket, :current_user, user)

          _ ->
            assign(socket, :current_user, nil)
        end
    end
  end
end
