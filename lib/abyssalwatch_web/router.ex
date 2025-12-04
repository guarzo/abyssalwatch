defmodule AbyssalwatchWeb.Router do
  use AbyssalwatchWeb, :router

  import AbyssalwatchWeb.Plugs.Auth,
    only: [fetch_current_user: 2, require_authenticated_user: 2, redirect_if_authenticated: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AbyssalwatchWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AbyssalwatchWeb.Plugs.SessionId
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Routes that require authentication
  pipeline :require_auth do
    plug :require_authenticated_user
  end

  # Routes that should redirect if already authenticated
  pipeline :redirect_if_auth do
    plug :redirect_if_authenticated
  end

  # Public routes (no auth required) - Phase 1: All features anonymous
  scope "/", AbyssalwatchWeb do
    pipe_through :browser

    # Redirect home to the main search page
    get "/", PageController, :home

    # Phase 1: Anonymous access to all core features
    live_session :public,
      on_mount: [{AbyssalwatchWeb.LiveAuth, :default}],
      session: {__MODULE__, :live_session_data, []} do
      live "/search", SearchLive, :index
      live "/optimize", OptimizationLive, :index
      live "/dashboard", DashboardLive, :index
      live "/watchlists", WatchlistLive, :index
      live "/notifications", NotificationLive, :index

      # Phase 4: Shareable fitting URLs (public access)
      live "/fit/:dna", FittingLive, :show
    end
  end

  # Auth routes (redirect if already logged in) - Phase 4 EVE SSO
  scope "/", AbyssalwatchWeb do
    pipe_through [:browser, :redirect_if_auth]

    live_session :auth, on_mount: [{AbyssalwatchWeb.LiveAuth, :redirect_if_authenticated}] do
      live "/sign-in", AuthLive, :index
    end
  end

  # EVE SSO OAuth2 callback - must be outside LiveView
  scope "/auth", AbyssalwatchWeb do
    pipe_through :browser

    # EVE SSO callback
    get "/eve/callback", AuthController, :eve_callback

    # Legacy callback for AshAuthentication (kept for compatibility)
    get "/callback", AuthController, :callback
  end

  # Logout route
  scope "/", AbyssalwatchWeb do
    pipe_through :browser

    delete "/logout", AuthController, :logout
    # Also allow GET for easier logout links
    get "/logout", AuthController, :logout
  end

  # ESI-related routes (require auth)
  scope "/esi", AbyssalwatchWeb do
    pipe_through [:browser, :require_auth]

    live_session :esi_authenticated,
      on_mount: [{AbyssalwatchWeb.LiveAuth, :require_authenticated}] do
      live "/fittings", ESIFittingsLive, :index
    end
  end

  # Silently handle Chrome DevTools well-known requests
  scope "/.well-known", AbyssalwatchWeb do
    pipe_through :api

    get "/appspecific/com.chrome.devtools.json", WellKnownController, :not_found
  end

  # Other scopes may use custom stacks.
  # scope "/api", AbyssalwatchWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:abyssalwatch, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AbyssalwatchWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  @doc """
  Extracts session data to pass to LiveViews.
  Called by live_session to populate the session parameter in mount/3.
  """
  def live_session_data(conn) do
    %{
      "session_id" => conn.assigns[:session_id],
      "user_id" => get_session(conn, :user_id),
      "character_id" => get_session(conn, :character_id)
    }
  end
end
