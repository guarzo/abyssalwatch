defmodule AbyssalwatchWeb.NotificationLive do
  @moduledoc """
  Match feed: dense table of notifications fired by watchlists.

  Pilots scan newest-first, click a row to expand it (which also marks
  unread notifications as read), open the contract on Mutamarket, or
  jump back to the source watchlist. New arrivals slide in silently
  via PubSub with a one-shot glyph flash; no toasts, no banners.

  See DESIGN.md and PRODUCT.md for the visual language.
  """
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Watchlists.{Notification, Notifier, Watchlist}

  @mutamarket_module_url "https://mutamarket.com/modules/"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    user_id = user && user.id

    if connected?(socket) and user_id do
      Notifier.subscribe(user_id)
    end

    notifications = load_notifications(user_id, nil)
    watchlists = load_user_watchlists(user_id)

    {:ok,
     socket
     |> assign(:active, :notifications)
     |> assign(:user_id, user_id)
     |> assign(:notifications, notifications)
     |> assign(:watchlists, watchlists)
     |> assign(:unread_count, count_unread(notifications))
     |> assign(:filter, "all")
     |> assign(:watchlist_filter, nil)
     |> assign(:expanded_id, nil)
     |> assign(:confirming_delete_id, nil)
     |> assign(:flash_id, nil)}
  end

  # ── URL ────────────────────────────────────────────────────────────

  @impl true
  def handle_params(params, _uri, socket) do
    filter = Map.get(params, "filter", "all")
    filter = if filter in ["all", "unread", "read"], do: filter, else: "all"
    watchlist_id = Map.get(params, "watchlist")
    watchlist_id = if watchlist_id == "", do: nil, else: watchlist_id

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

  # ── Filters ────────────────────────────────────────────────────────

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/notifications?#{filter_params(filter, socket.assigns.watchlist_filter)}"
     )}
  end

  @impl true
  def handle_event("filter_watchlist", %{"watchlist" => raw}, socket) do
    wid = if raw == "", do: nil, else: raw

    {:noreply,
     push_patch(socket, to: ~p"/notifications?#{filter_params(socket.assigns.filter, wid)}")}
  end

  @impl true
  def handle_event("clear_watchlist_filter", _params, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/notifications?#{filter_params(socket.assigns.filter, nil)}")}
  end

  # ── Row toggle (also marks read) ───────────────────────────────────

  @impl true
  def handle_event("toggle_row", %{"id" => id}, socket) do
    cond do
      socket.assigns.expanded_id == id ->
        {:noreply,
         socket
         |> assign(:expanded_id, nil)
         |> assign(:confirming_delete_id, nil)}

      true ->
        socket =
          socket
          |> assign(:expanded_id, id)
          |> assign(:confirming_delete_id, nil)

        case find_notification(socket.assigns.notifications, id) do
          %{read: false} = n -> mark_read_now(socket, n)
          _ -> {:noreply, socket}
        end
    end
  end

  # ── Mark all read ──────────────────────────────────────────────────

  @impl true
  def handle_event("mark_all_read", _params, socket) do
    input =
      Ash.ActionInput.for_action(Notification, :mark_all_read_for_user, %{
        user_id: socket.assigns.user_id
      })

    case Ash.run_action(input) do
      {:ok, _count} ->
        notifications = Enum.map(socket.assigns.notifications, &%{&1 | read: true})
        Notifier.broadcast_all_read(socket.assigns.user_id)

        {:noreply,
         socket
         |> assign(:notifications, notifications)
         |> assign(:unread_count, 0)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to mark notifications as read")}
    end
  end

  # ── Delete (inline confirm) ───────────────────────────────────────

  @impl true
  def handle_event("request_delete", %{"id" => id}, socket) do
    Process.send_after(self(), {:cancel_delete, id}, 6_000)
    {:noreply, assign(socket, :confirming_delete_id, id)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirming_delete_id, nil)}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    case find_notification(socket.assigns.notifications, id) do
      nil ->
        {:noreply, assign(socket, :confirming_delete_id, nil)}

      notification ->
        case Ash.destroy(notification) do
          :ok ->
            notifications = Enum.reject(socket.assigns.notifications, &(&1.id == id))
            Notifier.broadcast_notification_deleted(socket.assigns.user_id, id)

            {:noreply,
             socket
             |> assign(:notifications, notifications)
             |> assign(:unread_count, count_unread(notifications))
             |> assign(:expanded_id, nil)
             |> assign(:confirming_delete_id, nil)}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:confirming_delete_id, nil)
             |> put_flash(:error, "Failed to delete notification")}
        end
    end
  end

  # ── Keyboard ──────────────────────────────────────────────────────

  @impl true
  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    cond do
      socket.assigns.confirming_delete_id ->
        {:noreply, assign(socket, :confirming_delete_id, nil)}

      socket.assigns.expanded_id ->
        {:noreply, assign(socket, :expanded_id, nil)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  defp mark_read_now(socket, notification) do
    case Ash.update(notification, %{}, action: :mark_read) do
      {:ok, updated} ->
        notifications = update_notification_in_list(socket.assigns.notifications, updated)
        Notifier.broadcast_notification_read(socket.assigns.user_id, notification.id)

        {:noreply,
         socket
         |> assign(:notifications, notifications)
         |> assign(:unread_count, count_unread(notifications))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to mark notification as read")}
    end
  end

  # ── PubSub ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:new_notification, payload}, socket) do
    notifications =
      load_notifications(socket.assigns.user_id, socket.assigns.watchlist_filter)

    Process.send_after(self(), :clear_flash_id, 1000)

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, count_unread(notifications))
     |> assign(:flash_id, payload[:id] || payload["id"])}
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
    notifications = Enum.map(socket.assigns.notifications, &%{&1 | read: true})

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
     |> assign(:unread_count, count_unread(notifications))
     |> assign(
       :expanded_id,
       if(socket.assigns.expanded_id == notification_id,
         do: nil,
         else: socket.assigns.expanded_id
       )
     )}
  end

  @impl true
  def handle_info({:cancel_delete, id}, socket) do
    if socket.assigns.confirming_delete_id == id do
      {:noreply, assign(socket, :confirming_delete_id, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:clear_flash_id, socket) do
    {:noreply, assign(socket, :flash_id, nil)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # ── Data helpers ──────────────────────────────────────────────────

  defp load_notifications(nil, _), do: []

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

  defp filter_params(filter, nil), do: %{"filter" => filter}
  defp filter_params(filter, wid), do: %{"filter" => filter, "watchlist" => wid}

  defp find_notification(notifications, id), do: Enum.find(notifications, &(&1.id == id))

  defp update_notification_in_list(notifications, updated) do
    Enum.map(notifications, fn n -> if n.id == updated.id, do: updated, else: n end)
  end

  defp count_unread(notifications), do: Enum.count(notifications, &(not &1.read))

  defp filtered_notifications(notifications, "all"), do: notifications

  defp filtered_notifications(notifications, "unread"),
    do: Enum.filter(notifications, &(not &1.read))

  defp filtered_notifications(notifications, "read"), do: Enum.filter(notifications, & &1.read)

  defp watchlist_name(_watchlists, nil), do: nil

  defp watchlist_name(watchlists, id) do
    case Enum.find(watchlists, &(&1.id == id)) do
      nil -> nil
      w -> w.name
    end
  end

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    filtered = filtered_notifications(assigns.notifications, assigns.filter)
    total = length(assigns.notifications)
    read_count = total - assigns.unread_count

    assigns =
      assigns
      |> assign(:filtered_notifications, filtered)
      |> assign(:total, total)
      |> assign(:read_count, read_count)
      |> assign(
        :active_watchlist_name,
        watchlist_name(assigns.watchlists, assigns.watchlist_filter)
      )

    ~H"""
    <div id="notifications-root" phx-window-keydown="keydown" phx-key="Escape">
      <header class="flex items-end justify-between gap-6 pb-4 mb-5 border-b border-rule-1">
        <div>
          <h1 class="text-[22px] leading-[30px] font-semibold text-ink-1 tracking-tight">
            Notifications
          </h1>
          <p class="mt-1 text-[13px] text-ink-3">
            <%= if @total == 0 do %>
              No matches yet.
            <% else %>
              <span class="tnum">{@total}</span>
              total
              <span :if={@unread_count > 0}>
                <span class="text-ink-4">·</span>
                <span class="tnum text-ink-2">{@unread_count}</span> unread
              </span>
            <% end %>
          </p>
        </div>
        <div class="flex items-center gap-2">
          <button
            :if={@unread_count > 0}
            type="button"
            class="btn btn-sm"
            phx-click="mark_all_read"
          >
            Mark all read
          </button>
        </div>
      </header>

      <%= if @total == 0 do %>
        <.empty_state />
      <% else %>
        <.filter_row
          filter={@filter}
          total={@total}
          unread_count={@unread_count}
          read_count={@read_count}
          watchlists={@watchlists}
          watchlist_filter={@watchlist_filter}
        />

        <%= if Enum.empty?(@filtered_notifications) do %>
          <.empty_filtered
            filter={@filter}
            watchlist_filter={@watchlist_filter}
            active_watchlist_name={@active_watchlist_name}
          />
        <% else %>
          <.notifications_table
            notifications={@filtered_notifications}
            watchlists={@watchlists}
            expanded_id={@expanded_id}
            confirming_delete_id={@confirming_delete_id}
            flash_id={@flash_id}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── Empty states ──────────────────────────────────────────────────

  defp empty_state(assigns) do
    ~H"""
    <div class="panel max-w-2xl mx-auto">
      <div class="px-8 py-12 text-center">
        <p class="text-ink-1 text-[15px]">No matches yet.</p>
        <p class="mt-1.5 text-ink-3 text-[13px] leading-relaxed">
          New abyssal modules matching your watchlists will appear here.
        </p>
        <div class="mt-5">
          <.link navigate={~p"/watchlists"} class="btn btn-ghost">
            Browse watchlists <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :filter, :string, required: true
  attr :watchlist_filter, :any, required: true
  attr :active_watchlist_name, :any, required: true

  defp empty_filtered(assigns) do
    {title, subtitle} =
      case {assigns.filter, assigns.watchlist_filter} do
        {"unread", _} ->
          {"No unread notifications.", "You're caught up."}

        {"read", _} ->
          {"No read notifications yet.", "Open one to mark it read."}

        {"all", wid} when not is_nil(wid) ->
          {"No matches from this watchlist.", "Try a different watchlist or clear the filter."}

        _ ->
          {"No matches.", ""}
      end

    assigns = assign(assigns, :title, title) |> assign(:subtitle, subtitle)

    ~H"""
    <div class="panel">
      <div class="px-6 py-12 text-center">
        <p class="text-ink-1 text-[15px]">{@title}</p>
        <p :if={@subtitle != ""} class="mt-1 text-ink-3 text-[13px]">{@subtitle}</p>
        <div :if={@watchlist_filter} class="mt-4">
          <button type="button" class="btn btn-sm" phx-click="clear_watchlist_filter">
            Clear watchlist filter
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Filter row ────────────────────────────────────────────────────

  attr :filter, :string, required: true
  attr :total, :integer, required: true
  attr :unread_count, :integer, required: true
  attr :read_count, :integer, required: true
  attr :watchlists, :list, required: true
  attr :watchlist_filter, :any, required: true

  defp filter_row(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row md:items-center gap-3 md:gap-4 mb-4">
      <div class="inline-flex items-center gap-1 p-1 border border-rule-1 rounded-md self-start">
        <.filter_chip filter="all" current={@filter} label="All" count={@total} />
        <.filter_chip filter="unread" current={@filter} label="Unread" count={@unread_count} />
        <.filter_chip filter="read" current={@filter} label="Read" count={@read_count} />
      </div>

      <div class="md:ml-auto flex items-center gap-2">
        <span class="text-[12px] text-ink-3">Watchlist</span>
        <form phx-change="filter_watchlist" class="contents">
          <select name="watchlist" class="select w-56">
            <option value="" selected={is_nil(@watchlist_filter)}>All watchlists</option>
            <%= for w <- @watchlists do %>
              <option value={w.id} selected={@watchlist_filter == w.id}>{w.name}</option>
            <% end %>
          </select>
        </form>
      </div>
    </div>
    """
  end

  attr :filter, :string, required: true
  attr :current, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true

  defp filter_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-filter={@filter}
      class={[
        "px-2.5 py-1 text-[12px] rounded-sm transition-colors flex items-center gap-1.5",
        @current == @filter && "bg-surface-3 text-ink-1",
        @current != @filter && "text-ink-3 hover:text-ink-1 hover:bg-surface-2"
      ]}
      aria-pressed={@current == @filter}
    >
      <span>{@label}</span>
      <span class={[
        "tnum text-[11px]",
        @current == @filter && "text-ink-2",
        @current != @filter && "text-ink-4"
      ]}>
        {@count}
      </span>
    </button>
    """
  end

  # ── Table ─────────────────────────────────────────────────────────

  attr :notifications, :list, required: true
  attr :watchlists, :list, required: true
  attr :expanded_id, :any, required: true
  attr :confirming_delete_id, :any, required: true
  attr :flash_id, :any, required: true

  defp notifications_table(assigns) do
    ~H"""
    <div class="panel overflow-hidden">
      <table class="dense">
        <thead>
          <tr>
            <th class="w-6" aria-hidden="true"></th>
            <th>Module</th>
            <th>Watchlist</th>
            <th class="text-right">Score</th>
            <th class="text-right">Price (ISK)</th>
            <th class="text-right">Sent</th>
          </tr>
        </thead>
        <tbody>
          <%= for n <- @notifications do %>
            <% expanded = @expanded_id == n.id
            flashing = @flash_id == n.id and not n.read
            watchlist_name = watchlist_name_for(@watchlists, n)
            confirming = @confirming_delete_id == n.id %>
            <tr
              id={"row-#{n.id}"}
              phx-click="toggle_row"
              phx-value-id={n.id}
              class={[
                "cursor-pointer",
                expanded && "is-selected"
              ]}
            >
              <td class="text-center" aria-hidden="true">
                <span class={[
                  "text-[10px] leading-none",
                  not n.read && "text-accent",
                  n.read && "text-ink-4",
                  flashing && "animate-glyph-flash"
                ]}>
                  {if n.read, do: "○", else: "●"}
                </span>
              </td>
              <td>
                <div class={[
                  "text-[13px]",
                  not n.read && "text-ink-1 font-medium",
                  n.read && "text-ink-2"
                ]}>
                  {n.module_name || "Unknown module"}
                </div>
              </td>
              <td class="text-ink-3 text-[12px]">
                {watchlist_name || "—"}
              </td>
              <td class="text-right">
                <%= if n.module_score do %>
                  <div class="inline-flex items-center justify-end gap-2">
                    <span class="tnum text-ink-1">{format_score(n.module_score)}</span>
                    <span class="block w-12 h-1 bg-surface-3 rounded-sm overflow-hidden">
                      <span
                        class="block h-full bg-accent"
                        style={"width: #{round(min(n.module_score, 1.0) * 100)}%"}
                      />
                    </span>
                  </div>
                <% else %>
                  <span class="text-ink-4">—</span>
                <% end %>
              </td>
              <td class="text-right tnum">{format_price_plain(n.module_price)}</td>
              <td class="text-right text-ink-3 tnum">{time_ago(n.sent_at)}</td>
            </tr>

            <%= if expanded do %>
              <tr id={"detail-#{n.id}"} class="is-selected">
                <td colspan="6" class="!h-auto !p-0">
                  <.row_detail
                    notification={n}
                    watchlist_name={watchlist_name}
                    confirming={confirming}
                  />
                </td>
              </tr>
            <% end %>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :notification, :any, required: true
  attr :watchlist_name, :any, required: true
  attr :confirming, :boolean, required: true

  defp row_detail(assigns) do
    contract_url =
      if assigns.notification.module_external_id,
        do: @mutamarket_module_url <> assigns.notification.module_external_id,
        else: nil

    assigns = assign(assigns, :contract_url, contract_url)

    ~H"""
    <div class="px-5 py-4 bg-surface-2 border-t border-rule-1">
      <%= if @notification.module_attributes && map_size(@notification.module_attributes) > 0 do %>
        <h3 class="text-[11px] uppercase tracking-wider text-ink-3 font-medium mb-2.5">
          Attributes
        </h3>
        <ul class="grid grid-cols-2 md:grid-cols-3 gap-x-6 gap-y-1.5 mb-4">
          <%= for {attr, value} <- Enum.sort_by(@notification.module_attributes, fn {k, _} -> humanize_attr(k) end) do %>
            <li class="flex items-baseline justify-between gap-3 text-[12px]">
              <span class="text-ink-3 truncate">{humanize_attr(attr)}</span>
              <span class="tnum text-ink-1 shrink-0">{format_attr_value(value)}</span>
            </li>
          <% end %>
        </ul>
      <% else %>
        <p class="text-[12px] text-ink-4 mb-4">No attribute data on this notification.</p>
      <% end %>

      <div class="flex items-center gap-2 flex-wrap">
        <a
          :if={@contract_url}
          href={@contract_url}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-sm btn-primary"
        >
          Open contract <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </a>

        <.link
          :if={@notification.watchlist_id}
          navigate={~p"/watchlists?id=#{@notification.watchlist_id}"}
          class="btn btn-sm"
        >
          Watch: {@watchlist_name || "watchlist"}
        </.link>

        <span class="flex-1"></span>

        <%= if @confirming do %>
          <span class="text-[12px] text-ink-3 mr-1">Delete this notification?</span>
          <button
            type="button"
            class="btn btn-sm btn-danger"
            phx-click="confirm_delete"
            phx-value-id={@notification.id}
          >
            Confirm delete
          </button>
          <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel_delete">
            Cancel
          </button>
        <% else %>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-danger"
            phx-click="request_delete"
            phx-value-id={@notification.id}
          >
            Delete
          </button>
        <% end %>
      </div>

      <p :if={@notification.module_external_id} class="mt-3 text-[11px] text-ink-4 font-mono">
        Module: {@notification.module_external_id}
      </p>
    </div>
    """
  end

  defp watchlist_name_for(watchlists, %{watchlist_id: id}) when not is_nil(id) do
    case Enum.find(watchlists, &(&1.id == id)) do
      nil -> nil
      w -> w.name
    end
  end

  defp watchlist_name_for(_, _), do: nil

  # ── Format ─────────────────────────────────────────────────────────

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

  defp format_price_plain(price) when is_number(price) do
    format_price_plain(Decimal.new(round(price)))
  end

  defp format_price_plain(_), do: "—"

  defp format_attr_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp format_attr_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_attr_value(value) when is_binary(value), do: value
  defp format_attr_value(%{"value" => v}), do: format_attr_value(v)
  defp format_attr_value(nil), do: "—"
  defp format_attr_value(value), do: to_string(value)

  defp humanize_attr(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize_attr(name), do: to_string(name)

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
