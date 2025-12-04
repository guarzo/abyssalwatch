defmodule AbyssalwatchWeb.AuthLive do
  @moduledoc """
  LiveView for authentication via EVE SSO.

  Users authenticate through EVE Online's OAuth2 service, which provides:
  - Character identity (name, portrait)
  - Access to ESI endpoints (fittings, etc.)
  - No password management needed
  """
  use Phoenix.LiveView, layout: false

  alias Abyssalwatch.Accounts.EVEAuth

  @impl true
  def mount(_params, session, socket) do
    # Generate a state token for CSRF protection
    state = EVEAuth.generate_state()

    # Store state in session for verification on callback
    {:ok,
     socket
     |> assign(:state, state)
     |> assign(:error, session["error"])
     |> assign(:return_to, session["return_to"] || "/dashboard")}
  end

  @impl true
  def handle_params(%{"error" => error}, _uri, socket) do
    {:noreply, assign(socket, :error, error)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("login_with_eve", _params, socket) do
    # Generate the EVE SSO authorization URL
    authorize_url = EVEAuth.authorize_url(socket.assigns.state)

    # Store state in session before redirect
    # This will be handled by the controller
    {:noreply,
     socket
     |> put_flash(:info, "Redirecting to EVE Online...")
     |> redirect(external: authorize_url)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200">
      <div class="card w-full max-w-md bg-base-100 shadow-xl">
        <div class="card-body">
          <!-- Header -->
          <div class="text-center mb-8">
            <h1 class="text-3xl font-bold text-primary">AbyssalWatch</h1>
            <p class="text-gray-500 mt-2">
              EVE Online Abyssal Module Analysis
            </p>
          </div>
          
    <!-- EVE Online logo/branding -->
          <div class="flex justify-center mb-6">
            <div class="w-24 h-24 rounded-full bg-gradient-to-br from-blue-600 to-blue-800 flex items-center justify-center shadow-lg">
              <svg
                class="w-16 h-16 text-white"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M12 21a9.004 9.004 0 008.716-6.747M12 21a9.004 9.004 0 01-8.716-6.747M12 21c2.485 0 4.5-4.03 4.5-9S14.485 3 12 3m0 18c-2.485 0-4.5-4.03-4.5-9S9.515 3 12 3m0 0a8.997 8.997 0 017.843 4.582M12 3a8.997 8.997 0 00-7.843 4.582m15.686 0A11.953 11.953 0 0112 10.5c-2.998 0-5.74-1.1-7.843-2.918m15.686 0A8.959 8.959 0 0121 12c0 .778-.099 1.533-.284 2.253m0 0A17.919 17.919 0 0112 16.5c-3.162 0-6.133-.815-8.716-2.247m0 0A9.015 9.015 0 013 12c0-1.605.42-3.113 1.157-4.418"
                />
              </svg>
            </div>
          </div>
          
    <!-- Error message -->
          <%= if @error do %>
            <div class="alert alert-error mb-4">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="stroke-current shrink-0 h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              <span>{@error}</span>
            </div>
          <% end %>
          
    <!-- Description -->
          <div class="text-center mb-6">
            <p class="text-sm text-gray-600">
              Sign in with your EVE Online account to access all features including watchlists,
              notifications, and character fittings.
            </p>
          </div>
          
    <!-- EVE SSO Login Button -->
          <button
            phx-click="login_with_eve"
            class="btn btn-lg w-full bg-[#1d1d1d] hover:bg-[#2a2a2a] text-white border-0 gap-2"
          >
            <svg class="w-6 h-6" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z" />
              <path d="M12 6c-3.31 0-6 2.69-6 6s2.69 6 6 6 6-2.69 6-6-2.69-6-6-6zm0 10c-2.21 0-4-1.79-4-4s1.79-4 4-4 4 1.79 4 4-1.79 4-4 4z" />
            </svg>
            Log in with EVE Online
          </button>
          
    <!-- Permissions info -->
          <div class="mt-6 text-center">
            <p class="text-xs text-gray-500 mb-2">This app will request permission to:</p>
            <ul class="text-xs text-gray-500 space-y-1">
              <li class="flex items-center justify-center gap-1">
                <svg
                  class="w-4 h-4 text-success"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                View your character name and portrait
              </li>
              <li class="flex items-center justify-center gap-1">
                <svg
                  class="w-4 h-4 text-success"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Read your ship fittings
              </li>
              <li class="flex items-center justify-center gap-1">
                <svg
                  class="w-4 h-4 text-success"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Save new ship fittings
              </li>
            </ul>
          </div>
          
    <!-- Privacy note -->
          <div class="mt-6 pt-4 border-t border-base-300">
            <p class="text-xs text-gray-500 text-center">
              We never see your EVE Online password. Authentication is handled securely by CCP Games.
            </p>
          </div>
          
    <!-- Continue without signing in -->
          <div class="mt-4 text-center">
            <a href="/search" class="link link-hover text-sm text-gray-500">
              Continue without signing in
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
