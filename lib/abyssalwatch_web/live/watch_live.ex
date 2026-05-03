defmodule AbyssalwatchWeb.WatchLive do
  @moduledoc """
  Unified watch surface — replaces the legacy Dashboard, Watchlists, and
  Notifications screens. One mental model: things you're tracking and what's
  happened to them.

  Page structure:

      WATCH                                       [+ New watchlist]
      Markets you're hunting · Matches as they arrive
      ─────────────────────────────────────────────────────────────
      ACTIVITY (notification feed; filterable)
      ─── YOUR WATCHLISTS ───────────────────────── N active
      [Watchlist card] [Watchlist card] ...

  URL contract (preserves the legacy deep links via redirects in the router):

  | Legacy                              | New                      |
  | ----------------------------------- | ------------------------ |
  | `/dashboard`                        | `/watch`                 |
  | `/watchlists`                       | `/watch`                 |
  | `/watchlists?action=new`            | `/watch?new=1`           |
  | `/watchlists?id=ID`                 | `/watch?wl=ID`           |
  | `/watchlists?action=edit&id=ID`     | `/watch?wl=ID&edit=1`    |
  | `/notifications`                    | `/watch`                 |
  | `/notifications?filter=unread`      | `/watch?show=unread`     |
  | `/notifications?watchlist=ID`       | `/watch?wl=ID`           |

  Auth: anonymous pilots see a sign-in CTA hero. Signed-in pilots see
  activity + watchlists.
  """
  use AbyssalwatchWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    {:ok,
     socket
     |> assign(:active, :watch)
     |> assign(:current_user, user)
     |> assign(:user_id, user && user.id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @user_id do %>
      <.signed_in_view />
    <% else %>
      <.signed_out_view />
    <% end %>
    """
  end

  defp signed_in_view(assigns) do
    ~H"""
    <section>
      <header class="mb-6">
        <span class="sidebar-kicker">Watch</span>
        <h1 class="text-display mt-3">Markets you're hunting</h1>
        <p class="text-body text-ink-3 mt-1">Matches as they arrive.</p>
      </header>

      <div class="panel">
        <div class="panel-body text-ink-3 text-sm">
          Activity feed and watchlists land here in the next pass.
        </div>
      </div>
    </section>
    """
  end

  defp signed_out_view(assigns) do
    ~H"""
    <section class="hero">
      <div class="hero-kicker">Watch</div>
      <h1 class="text-mono-display hero-headline">
        Sign in to track<span class="text-mono-display-tail">.</span>
      </h1>
      <p class="hero-sub">
        Anonymous searches still work. Saved watchlists and Discord pings need a pilot
        — sign in with EVE SSO and we'll start watching the market for you.
      </p>
      <div class="quick-hunts">
        <a href="/sign-in" class="btn btn-primary">Sign in with EVE SSO</a>
        <a href="/search" class="btn btn-ghost">Browse search</a>
      </div>
    </section>
    """
  end
end
