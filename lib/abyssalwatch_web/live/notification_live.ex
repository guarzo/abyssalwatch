defmodule AbyssalwatchWeb.NotificationLive do
  @moduledoc """
  LiveView for viewing and managing notifications.

  Displays notification history with real-time updates when
  new notifications arrive. Supports filtering by read status
  and watchlist.
  """
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Watchlists.{Notification, Notifier, Watchlist}

  @impl true
  def mount(_params, _session, socket) do
    # current_user is set by LiveAuth on_mount hook
    user = socket.assigns.current_user
    user_id = user && user.id

    if connected?(socket) && user_id do
      Notifier.subscribe(user_id)
    end

    notifications = load_notifications(user_id, nil)
    watchlists = load_user_watchlists(user_id)
    unread_count = count_unread(notifications)

    {:ok,
     socket
     |> assign(:user_id, user_id)
     |> assign(:notifications, notifications)
     |> assign(:watchlists, watchlists)
     |> assign(:unread_count, unread_count)
     |> assign(:filter, "all")
     |> assign(:watchlist_filter, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = Map.get(params, "filter", "all")
    watchlist_id = Map.get(params, "watchlist")

    filter = if filter in ["all", "unread", "read"], do: filter, else: "all"

    # Reload notifications if watchlist filter changed
    notifications =
      if watchlist_id != socket.assigns.watchlist_filter do
        load_notifications(socket.assigns.user_id, watchlist_id)
      else
        socket.assigns.notifications
      end

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:watchlist_filter, watchlist_id)
     |> assign(:notifications, notifications)
     |> assign(:unread_count, count_unread(notifications))}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    case find_notification(socket.assigns.notifications, id) do
      nil ->
        {:noreply, socket}

      notification ->
        case Ash.update(notification, %{}, action: :mark_read) do
          {:ok, updated} ->
            notifications = update_notification_in_list(socket.assigns.notifications, updated)

            # Broadcast the read status
            Notifier.broadcast_notification_read(socket.assigns.user_id, id)

            {:noreply,
             socket
             |> assign(:notifications, notifications)
             |> assign(:unread_count, count_unread(notifications))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to mark notification as read")}
        end
    end
  end

  @impl true
  def handle_event("mark_all_read", _params, socket) do
    # Use bulk action for efficiency
    input =
      Ash.ActionInput.for_action(Notification, :mark_all_read_for_user, %{
        user_id: socket.assigns.user_id
      })

    case Ash.run_action(input) do
      {:ok, count} ->
        # Update local state
        notifications =
          Enum.map(socket.assigns.notifications, fn n ->
            %{n | read: true}
          end)

        # Broadcast all read
        Notifier.broadcast_all_read(socket.assigns.user_id)

        {:noreply,
         socket
         |> assign(:notifications, notifications)
         |> assign(:unread_count, 0)
         |> put_flash(:info, "Marked #{count} notification(s) as read")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to mark notifications as read")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case find_notification(socket.assigns.notifications, id) do
      nil ->
        {:noreply, socket}

      notification ->
        case Ash.destroy(notification) do
          :ok ->
            notifications = Enum.reject(socket.assigns.notifications, &(&1.id == id))

            # Broadcast deletion
            Notifier.broadcast_notification_deleted(socket.assigns.user_id, id)

            {:noreply,
             socket
             |> assign(:notifications, notifications)
             |> assign(:unread_count, count_unread(notifications))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete notification")}
        end
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    params = build_filter_params(filter, socket.assigns.watchlist_filter)
    {:noreply, push_patch(socket, to: ~p"/notifications?#{params}")}
  end

  @impl true
  def handle_event("filter_watchlist", %{"watchlist" => watchlist_id}, socket) do
    watchlist_id = if watchlist_id == "", do: nil, else: watchlist_id
    params = build_filter_params(socket.assigns.filter, watchlist_id)
    {:noreply, push_patch(socket, to: ~p"/notifications?#{params}")}
  end

  # PubSub handlers

  @impl true
  def handle_info({:new_notification, payload}, socket) do
    # Reload notifications to get the new one
    notifications = load_notifications(socket.assigns.user_id, socket.assigns.watchlist_filter)

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, count_unread(notifications))
     |> put_flash(:info, "New match: #{payload.module_name}")}
  end

  @impl true
  def handle_info({:notification_read, notification_id}, socket) do
    notifications =
      Enum.map(socket.assigns.notifications, fn n ->
        if n.id == notification_id, do: %{n | read: true}, else: n
      end)

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, count_unread(notifications))}
  end

  @impl true
  def handle_info(:all_notifications_read, socket) do
    notifications =
      Enum.map(socket.assigns.notifications, fn n ->
        %{n | read: true}
      end)

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, 0)}
  end

  @impl true
  def handle_info({:notification_deleted, notification_id}, socket) do
    notifications = Enum.reject(socket.assigns.notifications, &(&1.id == notification_id))

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, count_unread(notifications))}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # Private helpers

  defp load_notifications(nil, _watchlist_id), do: []

  defp load_notifications(user_id, nil) do
    case Ash.read(Notification, action: :for_user, args: %{user_id: user_id}) do
      {:ok, notifications} -> notifications
      {:error, _} -> []
    end
  end

  defp load_notifications(user_id, watchlist_id) do
    case Ash.read(Notification,
           action: :for_user_and_watchlist,
           args: %{user_id: user_id, watchlist_id: watchlist_id}
         ) do
      {:ok, notifications} -> notifications
      {:error, _} -> []
    end
  end

  defp load_user_watchlists(nil), do: []

  defp load_user_watchlists(user_id) do
    case Ash.read(Watchlist, action: :for_user, args: %{user_id: user_id}) do
      {:ok, watchlists} -> watchlists
      {:error, _} -> []
    end
  end

  defp build_filter_params(filter, nil) do
    URI.encode_query(%{filter: filter})
  end

  defp build_filter_params(filter, watchlist_id) do
    URI.encode_query(%{filter: filter, watchlist: watchlist_id})
  end

  defp find_notification(notifications, id) do
    Enum.find(notifications, &(&1.id == id))
  end

  defp update_notification_in_list(notifications, updated) do
    Enum.map(notifications, fn n ->
      if n.id == updated.id, do: updated, else: n
    end)
  end

  defp count_unread(notifications) do
    Enum.count(notifications, fn n -> !n.read end)
  end

  defp filtered_notifications(notifications, "all"), do: notifications

  defp filtered_notifications(notifications, "unread"),
    do: Enum.filter(notifications, &(!&1.read))

  defp filtered_notifications(notifications, "read"), do: Enum.filter(notifications, & &1.read)

  @impl true
  def render(assigns) do
    filtered = filtered_notifications(assigns.notifications, assigns.filter)
    assigns = assign(assigns, :filtered_notifications, filtered)

    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="flex justify-between items-center mb-8">
        <div>
          <h1 class="text-3xl font-bold">Notifications</h1>
          <p class="text-sm text-gray-500 mt-1">
            {@unread_count} unread notification{if @unread_count != 1, do: "s"}
          </p>
        </div>

        <div class="flex gap-2">
          <button
            :if={@unread_count > 0}
            class="btn btn-ghost btn-sm"
            phx-click="mark_all_read"
          >
            Mark all as read
          </button>
        </div>
      </div>
      
    <!-- Filters -->
      <div class="flex flex-col md:flex-row gap-4 mb-6">
        <!-- Status filter tabs -->
        <div class="tabs tabs-boxed">
          <button
            class={"tab #{if @filter == "all", do: "tab-active"}"}
            phx-click="filter"
            phx-value-filter="all"
          >
            All ({length(@notifications)})
          </button>
          <button
            class={"tab #{if @filter == "unread", do: "tab-active"}"}
            phx-click="filter"
            phx-value-filter="unread"
          >
            Unread ({@unread_count})
          </button>
          <button
            class={"tab #{if @filter == "read", do: "tab-active"}"}
            phx-click="filter"
            phx-value-filter="read"
          >
            Read ({length(@notifications) - @unread_count})
          </button>
        </div>
        
    <!-- Watchlist filter dropdown -->
        <div class="form-control">
          <select
            class="select select-bordered select-sm"
            phx-change="filter_watchlist"
            name="watchlist"
          >
            <option value="" selected={is_nil(@watchlist_filter)}>All Watchlists</option>
            <%= for watchlist <- @watchlists do %>
              <option value={watchlist.id} selected={@watchlist_filter == watchlist.id}>
                {watchlist.name}
              </option>
            <% end %>
          </select>
        </div>
      </div>
      
    <!-- Notification list -->
      <%= if Enum.empty?(@filtered_notifications) do %>
        <div class="text-center py-12">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="mx-auto h-12 w-12 text-gray-400"
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
          <h3 class="mt-2 text-sm font-medium">No notifications</h3>
          <p class="mt-1 text-sm text-gray-500">
            {case @filter do
              "unread" -> "You've read all your notifications."
              "read" -> "No read notifications yet."
              _ -> "Notifications will appear when modules match your watchlists."
            end}
          </p>
        </div>
      <% else %>
        <div class="space-y-4">
          <%= for notification <- @filtered_notifications do %>
            <div class={"card bg-base-200 #{unless notification.read, do: "border-l-4 border-primary"}"}>
              <div class="card-body p-4">
                <div class="flex justify-between items-start">
                  <div class="flex-1">
                    <div class="flex items-center gap-2">
                      <h3 class="font-semibold">
                        {notification.module_name || "Unknown Module"}
                      </h3>
                      <span :if={!notification.read} class="badge badge-primary badge-sm">New</span>
                    </div>

                    <p class="text-sm text-gray-500 mt-1">
                      Matched watchlist criteria
                    </p>

                    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-3 text-sm">
                      <div>
                        <span class="text-gray-500">Price:</span>
                        <span class="font-medium ml-1">
                          {format_price(notification.module_price)}
                        </span>
                      </div>
                      <div>
                        <span class="text-gray-500">Score:</span>
                        <span class="font-medium ml-1">
                          {if notification.module_score,
                            do: Float.round(notification.module_score, 2),
                            else: "N/A"}
                        </span>
                      </div>
                      <div>
                        <span class="text-gray-500">Module ID:</span>
                        <span class="font-mono text-xs ml-1">{notification.module_external_id}</span>
                      </div>
                      <div>
                        <span class="text-gray-500">Sent:</span>
                        <span class="ml-1">{format_time_ago(notification.sent_at)}</span>
                      </div>
                    </div>

                    <%= if notification.module_attributes && map_size(notification.module_attributes) > 0 do %>
                      <details class="mt-3">
                        <summary class="text-sm text-gray-500 cursor-pointer hover:text-gray-700">
                          View attributes ({map_size(notification.module_attributes)})
                        </summary>
                        <div class="mt-2 grid grid-cols-2 md:grid-cols-4 gap-2 text-xs">
                          <%= for {attr, value} <- notification.module_attributes do %>
                            <div>
                              <span class="text-gray-500">{attr}:</span>
                              <span class="font-medium ml-1">{format_attribute_value(value)}</span>
                            </div>
                          <% end %>
                        </div>
                      </details>
                    <% end %>
                  </div>

                  <div class="flex gap-2">
                    <button
                      :if={!notification.read}
                      class="btn btn-sm btn-ghost"
                      phx-click="mark_read"
                      phx-value-id={notification.id}
                      title="Mark as read"
                    >
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        class="h-4 w-4"
                        fill="none"
                        viewBox="0 0 24 24"
                        stroke="currentColor"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M5 13l4 4L19 7"
                        />
                      </svg>
                    </button>
                    <button
                      class="btn btn-sm btn-ghost text-error"
                      phx-click="delete"
                      phx-value-id={notification.id}
                      title="Delete"
                    >
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        class="h-4 w-4"
                        fill="none"
                        viewBox="0 0 24 24"
                        stroke="currentColor"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                        />
                      </svg>
                    </button>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_price(nil), do: "N/A"

  defp format_price(%Decimal{} = price) do
    price
    |> Decimal.round(0)
    |> Decimal.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
    |> Kernel.<>(" ISK")
  end

  defp format_price(price) when is_number(price) do
    format_price(Decimal.new(round(price)))
  end

  defp format_price(_), do: "N/A"

  defp format_time_ago(nil), do: "unknown"

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      true -> "#{div(diff, 86400)} days ago"
    end
  end

  defp format_attribute_value(value) when is_float(value) do
    Float.round(value, 2) |> to_string()
  end

  defp format_attribute_value(value), do: to_string(value)
end
