defmodule AbyssalwatchWeb.DashboardLive do
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Market.ModuleType
  alias Abyssalwatch.Market.Mutamarket.Cache
  alias Abyssalwatch.Watchlists.{Watchlist, Notification, Monitor, Notifier}
  alias Abyssalwatch.Preferences.Store, as: Preferences

  @impl true
  def mount(_params, session, socket) do
    # current_user is set by LiveAuth on_mount hook
    user = socket.assigns[:current_user]
    user_id = user && user.id
    session_id = session["session_id"]

    if connected?(socket) do
      # Refresh stats every 30 seconds
      :timer.send_interval(30_000, self(), :refresh_stats)

      # Subscribe to notifications if user is logged in
      if user_id do
        Notifier.subscribe(user_id)
      end
    end

    # Get recent searches from preferences store
    recent_searches = Preferences.get_recent_searches(session_id)

    # Calculate market stats from cache
    market_stats = calculate_market_stats()

    {:ok,
     socket
     |> assign(:session_id, session_id)
     |> assign(:user_id, user_id)
     |> assign(:module_types, load_module_types())
     |> assign(:cache_stats, Cache.stats())
     |> assign(:stats, calculate_stats(user_id))
     |> assign(:market_stats, market_stats)
     |> assign(:monitor_status, get_monitor_status())
     |> assign(:recent_searches, recent_searches)}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply,
     socket
     |> assign(:cache_stats, Cache.stats())
     |> assign(:stats, calculate_stats(socket.assigns.user_id))
     |> assign(:market_stats, calculate_market_stats())
     |> assign(:monitor_status, get_monitor_status())}
  end

  @impl true
  def handle_info({:new_notification, payload}, socket) do
    {:noreply,
     socket
     |> assign(:stats, calculate_stats(socket.assigns.user_id))
     |> put_flash(:info, "New match for #{payload.watchlist_name}: #{payload.module_name}")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp load_module_types do
    case Ash.read(ModuleType) do
      {:ok, types} -> types
      {:error, _} -> []
    end
  end

  defp calculate_stats(user_id) do
    base_stats = %{
      module_type_count: length(load_module_types()),
      cache_size: Cache.stats().size,
      cache_memory: Cache.stats().memory
    }

    watchlist_stats = calculate_watchlist_stats(user_id)
    Map.merge(base_stats, watchlist_stats)
  end

  defp calculate_watchlist_stats(nil) do
    %{
      watchlist_count: 0,
      active_watchlist_count: 0,
      unread_notification_count: 0,
      total_matches: 0
    }
  end

  defp calculate_watchlist_stats(user_id) do
    watchlists =
      case Ash.read(Watchlist, action: :for_user, args: %{user_id: user_id}) do
        {:ok, watchlists} -> watchlists
        {:error, _} -> []
      end

    unread_notifications =
      case Ash.read(Notification, action: :unread_for_user, args: %{user_id: user_id}) do
        {:ok, notifications} -> notifications
        {:error, _} -> []
      end

    %{
      watchlist_count: length(watchlists),
      active_watchlist_count: Enum.count(watchlists, & &1.notifications_enabled),
      unread_notification_count: length(unread_notifications),
      total_matches: Enum.sum(Enum.map(watchlists, & &1.match_count))
    }
  end

  defp get_monitor_status do
    try do
      Monitor.status()
    rescue
      _ -> %{paused: true, last_check: nil, stats: %{total_checks: 0, total_matches: 0}}
    catch
      :exit, _ -> %{paused: true, last_check: nil, stats: %{total_checks: 0, total_matches: 0}}
    end
  end

  defp calculate_market_stats do
    # Get all cached module data
    cached_modules = get_all_cached_modules()

    if Enum.empty?(cached_modules) do
      %{
        active_listings: 0,
        average_value: Decimal.new(0),
        top_modules: []
      }
    else
      prices =
        cached_modules
        |> Enum.map(fn m -> m[:price] || Decimal.new(0) end)
        |> Enum.reject(&(Decimal.compare(&1, Decimal.new(0)) == :eq))

      avg_value =
        if Enum.empty?(prices) do
          Decimal.new(0)
        else
          total = Enum.reduce(prices, Decimal.new(0), &Decimal.add/2)
          Decimal.div(total, Decimal.new(length(prices)))
        end

      # Get top modules by price (most valuable)
      top_modules =
        cached_modules
        |> Enum.filter(fn m ->
          price = m[:price] || Decimal.new(0)
          Decimal.compare(price, Decimal.new(0)) == :gt
        end)
        |> Enum.sort_by(fn m -> Decimal.to_float(m[:price] || Decimal.new(0)) end, :desc)
        |> Enum.take(5)

      %{
        active_listings: length(cached_modules),
        average_value: avg_value,
        top_modules: top_modules
      }
    end
  end

  defp get_all_cached_modules do
    # Get all cached data from the ETS cache
    # Cache stores data by key {:modules_by_type, type_id}
    try do
      Cache.all_entries()
      |> Enum.flat_map(fn
        {{:modules_by_type, _type_id}, modules} when is_list(modules) -> modules
        _ -> []
      end)
    rescue
      _ -> []
    catch
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <h1 class="text-3xl font-bold mb-8">AbyssalWatch Dashboard</h1>
      
    <!-- Stats Cards - Row 1 -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-4">
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Module Types</div>
          <div class="stat-value text-primary">{@stats.module_type_count}</div>
          <div class="stat-desc">Supported abyssal types</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-secondary">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Watchlists</div>
          <div class="stat-value text-secondary">{@stats.watchlist_count}</div>
          <div class="stat-desc">{@stats.active_watchlist_count} active</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-warning">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M7 8h10M7 12h4m1 8l-4-4H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-3l-4 4z"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Notifications</div>
          <div class="stat-value text-warning">{@stats.unread_notification_count}</div>
          <div class="stat-desc">Unread alerts</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-success">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Total Matches</div>
          <div class="stat-value text-success">{@stats.total_matches}</div>
          <div class="stat-desc">Modules matched</div>
        </div>
      </div>
      
    <!-- Stats Cards - Row 2 -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-accent">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 10V3L4 14h7v7l9-11h-7z"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Cache Entries</div>
          <div class="stat-value text-accent">{@cache_stats.size}</div>
          <div class="stat-desc">Cached API responses</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-info">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 8h14M5 8a2 2 0 110-4h14a2 2 0 110 4M5 8v10a2 2 0 002 2h10a2 2 0 002-2V8m-9 4h4"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Cache Memory</div>
          <div class="stat-value text-info">{format_memory(@cache_stats.memory)}</div>
          <div class="stat-desc">ETS memory usage</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Monitor</div>
          <div class="stat-value text-lg">
            {if @monitor_status.paused, do: "Paused", else: "Running"}
          </div>
          <div class="stat-desc">
            <%= if @monitor_status.last_check do %>
              Last: {format_time_ago(@monitor_status.last_check)}
            <% else %>
              Not yet checked
            <% end %>
          </div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-secondary">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 6V4m0 2a2 2 0 100 4m0-4a2 2 0 110 4m-6 8a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4m6 6v10m6-2a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Status</div>
          <div class="stat-value text-lg text-success">Online</div>
          <div class="stat-desc">All systems operational</div>
        </div>
      </div>
      
    <!-- Market Stats -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 mb-8">
        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Active Listings</div>
          <div class="stat-value text-primary">{@market_stats.active_listings}</div>
          <div class="stat-desc">Modules in cache</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-secondary">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Average Value</div>
          <div class="stat-value text-secondary text-lg">
            {format_isk(@market_stats.average_value)}
          </div>
          <div class="stat-desc">Across all cached modules</div>
        </div>

        <div class="stat bg-base-200 rounded-lg">
          <div class="stat-figure text-accent">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="inline-block w-8 h-8 stroke-current"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6"
              >
              </path>
            </svg>
          </div>
          <div class="stat-title">Top Module Value</div>
          <div class="stat-value text-accent text-lg">
            <%= if Enum.any?(@market_stats.top_modules) do %>
              {format_isk(hd(@market_stats.top_modules)[:price])}
            <% else %>
              N/A
            <% end %>
          </div>
          <div class="stat-desc">Highest priced in cache</div>
        </div>
      </div>
      
    <!-- Top Modules Table -->
      <%= if Enum.any?(@market_stats.top_modules) do %>
        <div class="card bg-base-200 mb-8">
          <div class="card-body">
            <h2 class="card-title mb-4">Top Modules by Value</h2>
            <div class="overflow-x-auto">
              <table class="table table-zebra w-full">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Type</th>
                    <th>Price</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for module <- @market_stats.top_modules do %>
                    <tr>
                      <td class="font-medium">{module[:name] || "Unknown"}</td>
                      <td class="text-sm text-gray-500">{module[:type_name] || "N/A"}</td>
                      <td class="font-mono">{format_isk(module[:price])}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      <% end %>
      
    <!-- Quick Actions -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Quick Actions</h2>
            <div class="flex flex-wrap gap-2">
              <a href="/search" class="btn btn-primary">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5 mr-2"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                  />
                </svg>
                Search Modules
              </a>
              <a href="/watchlists" class="btn btn-secondary">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5 mr-2"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
                  />
                </svg>
                Watchlists
              </a>
              <a href="/notifications" class="btn btn-accent">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5 mr-2"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M7 8h10M7 12h4m1 8l-4-4H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-3l-4 4z"
                  />
                </svg>
                Notifications
                <%= if @stats.unread_notification_count > 0 do %>
                  <span class="badge badge-warning">{@stats.unread_notification_count}</span>
                <% end %>
              </a>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">System Health</h2>
            <div class="space-y-2">
              <div class="flex justify-between items-center">
                <span>Database</span>
                <span class="badge badge-success">Connected</span>
              </div>
              <div class="flex justify-between items-center">
                <span>Cache</span>
                <span class="badge badge-success">Active</span>
              </div>
              <div class="flex justify-between items-center">
                <span>Rate Limiter</span>
                <span class="badge badge-success">Running</span>
              </div>
              <div class="flex justify-between items-center">
                <span>Watchlist Monitor</span>
                <span class={"badge #{if @monitor_status.paused, do: "badge-warning", else: "badge-success"}"}>
                  {if @monitor_status.paused, do: "Paused", else: "Running"}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Recent Searches -->
      <%= if Enum.any?(@recent_searches) do %>
        <div class="card bg-base-200 mb-8">
          <div class="card-body">
            <h2 class="card-title mb-4">Recent Searches</h2>
            <div class="overflow-x-auto">
              <table class="table table-zebra w-full">
                <thead>
                  <tr>
                    <th>Module Type</th>
                    <th>Preset</th>
                    <th>Results</th>
                    <th>Time</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for search <- @recent_searches do %>
                    <tr>
                      <td class="font-medium">{search.type_name}</td>
                      <td>
                        <span class="badge badge-outline">
                          {String.capitalize(search.preset)}
                        </span>
                      </td>
                      <td>{search.result_count} modules</td>
                      <td class="text-sm text-gray-500">
                        {format_search_time(search.searched_at)}
                      </td>
                      <td>
                        <a
                          href={"/search?type_id=#{search.type_id}&preset=#{search.preset}"}
                          class="btn btn-xs btn-ghost"
                        >
                          Search Again
                        </a>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      <% end %>
      
    <!-- Module Types -->
      <div class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title mb-4">Supported Module Types</h2>
          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Category</th>
                  <th>Slot</th>
                  <th>EVE Type ID</th>
                  <th>Action</th>
                </tr>
              </thead>
              <tbody>
                <%= for type <- @module_types do %>
                  <tr>
                    <td class="font-medium">{type.name}</td>
                    <td>
                      <span class={"badge #{category_badge_class(type.category)}"}>
                        {type.category}
                      </span>
                    </td>
                    <td>
                      <span class={"badge #{slot_badge_class(type.slot_type)}"}>
                        {type.slot_type}
                      </span>
                    </td>
                    <td class="font-mono text-sm">{type.eve_type_id}</td>
                    <td>
                      <a href={"/search?type_id=#{type.eve_type_id}"} class="btn btn-xs btn-ghost">
                        Search
                      </a>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_time_ago(nil), do: "never"

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      true -> "#{div(diff, 86400)} days ago"
    end
  end

  defp format_search_time(nil), do: "unknown"

  defp format_search_time(%DateTime{} = datetime) do
    format_time_ago(datetime)
  end

  defp format_search_time(_), do: "unknown"

  defp format_memory(words) when is_integer(words) do
    bytes = words * :erlang.system_info(:wordsize)

    cond do
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_memory(_), do: "N/A"

  defp category_badge_class(category) do
    case category do
      "Tackle" -> "badge-error"
      "Propulsion" -> "badge-info"
      "Shield" -> "badge-primary"
      "Armor" -> "badge-warning"
      "Tank" -> "badge-success"
      _ -> "badge-ghost"
    end
  end

  defp slot_badge_class(slot_type) do
    case slot_type do
      :high -> "badge-error"
      :med -> "badge-warning"
      :low -> "badge-success"
      :rig -> "badge-info"
      _ -> "badge-ghost"
    end
  end

  defp format_isk(nil), do: "N/A"

  defp format_isk(%Decimal{} = price) do
    price
    |> Decimal.round(0)
    |> Decimal.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
    |> Kernel.<>(" ISK")
  end

  defp format_isk(price) when is_number(price) do
    format_isk(Decimal.new(round(price)))
  end

  defp format_isk(_), do: "N/A"
end
