defmodule AbyssalwatchWeb.DashboardLive do
  @moduledoc """
  Quiet status landing page.

  Three sections in a single reading column: recent unread matches,
  active watchlists, recent searches. Operator metrics (cache size,
  ETS memory, module-type counts) are deliberately absent unless
  something is actually broken (monitor paused), in which case a
  small footer surfaces it. Anonymous pilots see a sign-in CTA in
  place of the activity sections.

  See PRODUCT.md and DESIGN.md for the visual language.
  """
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Watchlists.{Watchlist, Notification, Monitor, Notifier}
  alias Abyssalwatch.Preferences.Store, as: Preferences

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]
    user_id = user && user.id
    session_id = session["session_id"]

    if connected?(socket) do
      :timer.send_interval(30_000, self(), :refresh)
      if user_id, do: Notifier.subscribe(user_id)
    end

    {:ok,
     socket
     |> assign(:active, :dashboard)
     |> assign(:user_id, user_id)
     |> assign(:current_user, user)
     |> assign(:session_id, session_id)
     |> load_dashboard()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_dashboard(socket)}
  end

  @impl true
  def handle_info({:new_notification, _payload}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("resume_monitor", _params, socket) do
    Monitor.resume()
    {:noreply, load_dashboard(socket)}
  end

  defp load_dashboard(socket) do
    user_id = socket.assigns.user_id

    socket
    |> assign(:recent_matches, load_recent_matches(user_id))
    |> assign(:active_watchlists, load_active_watchlists(user_id))
    |> assign(:unread_count, load_unread_count(user_id))
    |> assign(:active_watchlist_count, load_active_watchlist_count(user_id))
    |> assign(:recent_searches, Preferences.get_recent_searches(socket.assigns.session_id))
    |> assign(:monitor_status, get_monitor_status())
  end

  defp load_recent_matches(nil), do: []

  defp load_recent_matches(user_id) do
    unread =
      case Ash.read(Notification, action: :unread_for_user, args: %{user_id: user_id}) do
        {:ok, ns} -> Enum.take(ns, 5)
        {:error, _} -> []
      end

    if Enum.empty?(unread) do
      case Ash.read(Notification, action: :for_user, args: %{user_id: user_id}) do
        {:ok, ns} -> Enum.take(ns, 3)
        {:error, _} -> []
      end
    else
      unread
    end
  end

  defp load_active_watchlists(nil), do: []

  defp load_active_watchlists(user_id) do
    case Ash.read(Watchlist, action: :for_user, args: %{user_id: user_id}) do
      {:ok, watchlists} ->
        watchlists
        |> Enum.filter(& &1.notifications_enabled)
        |> Enum.sort_by(
          fn w -> {w.last_checked_at || ~U[1970-01-01 00:00:00Z], w.match_count || 0} end,
          :desc
        )
        |> Enum.take(3)

      {:error, _} ->
        []
    end
  end

  defp load_unread_count(nil), do: 0

  defp load_unread_count(user_id) do
    case Ash.read(Notification, action: :unread_for_user, args: %{user_id: user_id}) do
      {:ok, ns} -> length(ns)
      {:error, _} -> 0
    end
  end

  defp load_active_watchlist_count(nil), do: 0

  defp load_active_watchlist_count(user_id) do
    case Ash.read(Watchlist, action: :for_user, args: %{user_id: user_id}) do
      {:ok, watchlists} -> Enum.count(watchlists, & &1.notifications_enabled)
      {:error, _} -> 0
    end
  end

  defp get_monitor_status do
    Monitor.status()
  rescue
    _ -> %{paused: false, last_check: nil, stats: %{total_checks: 0, total_matches: 0}}
  catch
    :exit, _ -> %{paused: false, last_check: nil, stats: %{total_checks: 0, total_matches: 0}}
  end

  defp watchlist_name_for(_watchlists, nil), do: nil

  defp watchlist_name_for(watchlists, id) do
    case Enum.find(watchlists, &(&1.id == id)) do
      nil -> nil
      w -> w.name
    end
  end

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    signed_in = not is_nil(assigns.user_id)

    assigns =
      assigns
      |> assign(:signed_in, signed_in)
      |> assign(:has_recent_searches, Enum.any?(assigns.recent_searches))
      |> assign(:monitor_broken, monitor_broken?(assigns.monitor_status))

    ~H"""
    <div class="max-w-[720px] mx-auto">
      <header class="pb-5 mb-6 border-b border-rule-1">
        <%= if @signed_in do %>
          <h1 class="text-[22px] leading-[30px] font-semibold text-ink-1 tracking-tight">
            Welcome back, {@current_user.character_name}
          </h1>
          <p class="mt-1 text-[13px] text-ink-3">
            <.welcome_subtitle
              unread_count={@unread_count}
              active_watchlist_count={@active_watchlist_count}
            />
          </p>
        <% else %>
          <h1 class="text-[22px] leading-[30px] font-semibold text-ink-1 tracking-tight">
            Welcome
          </h1>
          <p class="mt-1 text-[13px] text-ink-3">
            Sign in to save watchlists and get notified on matches.
          </p>
        <% end %>
      </header>

      <%= if @signed_in do %>
        <.recent_matches_section
          matches={@recent_matches}
          watchlists={@active_watchlists}
        />
        <.active_watchlists_section watchlists={@active_watchlists} />
      <% else %>
        <.signed_out_panel />
      <% end %>

      <%= if @has_recent_searches do %>
        <.recent_searches_section searches={@recent_searches} />
      <% end %>

      <.monitor_footer :if={@monitor_broken} status={@monitor_status} />
    </div>
    """
  end

  attr :unread_count, :integer, required: true
  attr :active_watchlist_count, :integer, required: true

  defp welcome_subtitle(assigns) do
    ~H"""
    <%= cond do %>
      <% @unread_count == 0 and @active_watchlist_count == 0 -> %>
        Quiet so far.
      <% @unread_count == 0 -> %>
        <span class="tnum">{@active_watchlist_count}</span> active
        {pluralize(@active_watchlist_count, "watchlist", "watchlists")}.
      <% @active_watchlist_count == 0 -> %>
        <span class="tnum">{@unread_count}</span> unread
        {pluralize(@unread_count, "notification", "notifications")}.
      <% true -> %>
        <span class="tnum">{@unread_count}</span> unread
        {pluralize(@unread_count, "notification", "notifications")}
        <span class="text-ink-4">·</span>
        <span class="tnum">{@active_watchlist_count}</span> active
        {pluralize(@active_watchlist_count, "watchlist", "watchlists")}.
    <% end %>
    """
  end

  defp pluralize(1, s, _), do: s
  defp pluralize(_, _, p), do: p

  # ── Recent matches ────────────────────────────────────────────────

  attr :matches, :list, required: true
  attr :watchlists, :list, required: true

  defp recent_matches_section(assigns) do
    ~H"""
    <section class="mb-8">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="text-[11px] uppercase tracking-wider text-ink-3 font-medium">
          Recent matches
        </h2>
        <.link navigate={~p"/notifications"} class="text-[12px] text-ink-3 hover:text-ink-1">
          View all →
        </.link>
      </div>

      <%= if Enum.empty?(@matches) do %>
        <p class="text-[13px] text-ink-3">
          No matches yet. Watchlists check the market every few minutes.
        </p>
      <% else %>
        <ul class="divide-y divide-rule-1 border-y border-rule-1">
          <%= for n <- @matches do %>
            <li>
              <.link
                navigate={~p"/notifications"}
                class="flex items-center gap-3 px-1 py-2.5 hover:bg-surface-2 transition-colors"
              >
                <span
                  class={[
                    "text-[10px] leading-none",
                    not n.read && "text-accent",
                    n.read && "text-ink-4"
                  ]}
                  aria-hidden="true"
                >
                  <%= if n.read, do: "○", else: "●" %>
                </span>
                <span class="flex-1 min-w-0">
                  <span class={[
                    "block text-[13px] truncate",
                    not n.read && "text-ink-1 font-medium",
                    n.read && "text-ink-2"
                  ]}>
                    {n.module_name || "Unknown module"}
                  </span>
                  <span class="block text-[11px] text-ink-4 truncate">
                    {watchlist_name_for(@watchlists, n.watchlist_id) || "watchlist"}
                  </span>
                </span>
                <span class="text-[12px] text-ink-2 tnum shrink-0">
                  {format_score(n.module_score)}
                </span>
                <span class="text-[12px] text-ink-3 tnum shrink-0 w-24 text-right">
                  {format_price_plain(n.module_price)}
                </span>
                <span class="text-[11px] text-ink-4 tnum shrink-0 w-12 text-right">
                  {time_ago(n.sent_at)}
                </span>
              </.link>
            </li>
          <% end %>
        </ul>
      <% end %>
    </section>
    """
  end

  # ── Active watchlists ─────────────────────────────────────────────

  attr :watchlists, :list, required: true

  defp active_watchlists_section(assigns) do
    ~H"""
    <section class="mb-8">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="text-[11px] uppercase tracking-wider text-ink-3 font-medium">
          Active watchlists
        </h2>
        <.link navigate={~p"/watchlists"} class="text-[12px] text-ink-3 hover:text-ink-1">
          Manage →
        </.link>
      </div>

      <%= if Enum.empty?(@watchlists) do %>
        <p class="text-[13px] text-ink-3">
          No active watchlists.
          <.link navigate={~p"/watchlists?action=new"} class="text-ink-2 hover:text-ink-1 underline underline-offset-2 ml-1">
            Create one →
          </.link>
        </p>
      <% else %>
        <ul class="divide-y divide-rule-1 border-y border-rule-1">
          <%= for w <- @watchlists do %>
            <li>
              <.link
                navigate={~p"/watchlists?id=#{w.id}"}
                class="flex items-center gap-3 px-1 py-2.5 hover:bg-surface-2 transition-colors"
              >
                <span class="text-status-ready text-[10px] leading-none" aria-hidden="true">●</span>
                <span class="flex-1 min-w-0">
                  <span class="block text-[13px] text-ink-1 truncate">{w.name}</span>
                  <span class="block text-[11px] text-ink-4 truncate">
                    {w.module_type_name}
                  </span>
                </span>
                <span class="text-[12px] text-ink-2 tnum shrink-0">
                  <span class="tnum">{w.match_count || 0}</span>
                  {pluralize(w.match_count || 0, "match", "matches")}
                </span>
                <span class="text-[11px] text-ink-4 tnum shrink-0 w-20 text-right">
                  {if w.last_checked_at, do: "last " <> time_ago(w.last_checked_at), else: "—"}
                </span>
              </.link>
            </li>
          <% end %>
        </ul>
      <% end %>
    </section>
    """
  end

  # ── Recent searches ───────────────────────────────────────────────

  attr :searches, :list, required: true

  defp recent_searches_section(assigns) do
    assigns = assign(assigns, :searches, Enum.take(assigns.searches, 5))

    ~H"""
    <section class="mb-8">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="text-[11px] uppercase tracking-wider text-ink-3 font-medium">
          Recent searches
        </h2>
        <.link navigate={~p"/search"} class="text-[12px] text-ink-3 hover:text-ink-1">
          Open search →
        </.link>
      </div>

      <ul class="divide-y divide-rule-1 border-y border-rule-1">
        <%= for s <- @searches do %>
          <li>
            <.link
              navigate={~p"/search?type_id=#{s.type_id}&preset=#{s.preset}"}
              class="flex items-center gap-3 px-1 py-2.5 hover:bg-surface-2 transition-colors"
            >
              <span class="text-ink-3 text-[12px]" aria-hidden="true">▸</span>
              <span class="flex-1 min-w-0 text-[13px] text-ink-1 truncate">{s.type_name}</span>
              <span class="text-[11px] text-ink-4 capitalize shrink-0">{s.preset}</span>
              <span class="text-[11px] text-ink-4 tnum shrink-0 w-12 text-right">
                {time_ago(s.searched_at)}
              </span>
            </.link>
          </li>
        <% end %>
      </ul>
    </section>
    """
  end

  # ── Signed-out panel ──────────────────────────────────────────────

  defp signed_out_panel(assigns) do
    ~H"""
    <section class="panel mb-8">
      <div class="px-6 py-8 text-center">
        <p class="text-ink-1 text-[14px]">
          Sign in to enable watchlists and notifications.
        </p>
        <p class="mt-1 text-ink-3 text-[12px]">
          Anonymous searches still work; saved watchlists require a signed-in pilot.
        </p>
        <div class="mt-5">
          <.link href={~p"/sign-in"} class="btn btn-primary">
            Sign in with EVE SSO
          </.link>
        </div>
      </div>
    </section>
    """
  end

  # ── Monitor footer ────────────────────────────────────────────────

  attr :status, :map, required: true

  defp monitor_footer(assigns) do
    ~H"""
    <div class="mt-10 pt-4 border-t border-rule-1 flex items-center gap-3">
      <span class="text-status-error text-[10px] leading-none" aria-hidden="true">!</span>
      <span class="text-[12px] text-ink-3 flex-1">
        Monitor paused
        <%= if @status.last_check do %>
          <span class="text-ink-4">·</span> last check {time_ago(@status.last_check)}
        <% end %>
      </span>
      <button type="button" class="btn btn-sm" phx-click="resume_monitor">
        Resume
      </button>
    </div>
    """
  end

  defp monitor_broken?(%{paused: true}), do: true
  defp monitor_broken?(_), do: false

  # ── Format ────────────────────────────────────────────────────────

  defp format_score(score) when is_number(score),
    do: :erlang.float_to_binary(score * 1.0, decimals: 2)

  defp format_score(_), do: "—"

  defp format_price_plain(nil), do: "—"

  defp format_price_plain(%Decimal{} = price) do
    price
    |> Decimal.round(0)
    |> Decimal.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_price_plain(price) when is_number(price),
    do: format_price_plain(Decimal.new(round(price)))

  defp format_price_plain(_), do: "—"

  defp time_ago(nil), do: "—"

  defp time_ago(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp time_ago(_), do: "—"
end
