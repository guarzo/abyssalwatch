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

  alias Abyssalwatch.Watchlists.{Watchlist, Notification, Notifier}
  alias Abyssalwatch.Market.ModuleType

  @mutamarket_module_url "https://mutamarket.com/modules/"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    user_id = user && user.id

    if connected?(socket) and user_id do
      Notifier.subscribe(user_id)
      :timer.send_interval(30_000, self(), :refresh)
    end

    socket =
      socket
      |> assign(:active, :watch)
      |> assign(:current_user, user)
      |> assign(:user_id, user_id)
      |> assign(:show_filter, "all")
      |> assign(:watchlist_filter, nil)
      |> assign(:expanded_id, nil)
      |> assign(:flash_id, nil)
      |> assign(:drawer_mode, nil)
      |> assign(:editing_watchlist, nil)
      |> assign(:form_data, default_form_data())
      |> assign(:form_errors, %{})
      |> assign(:confirming_delete_watchlist_id, nil)
      |> assign(:confirming_delete_notification_id, nil)
      |> load_data()

    {:ok, socket}
  end

  defp load_data(socket) do
    user_id = socket.assigns.user_id
    # Preserve the active watchlist filter across refreshes — the 30s
    # :refresh tick must not silently widen the activity feed.
    notifications = load_notifications(user_id, socket.assigns[:watchlist_filter])
    watchlists = load_watchlists(user_id)
    module_types = load_module_types()

    socket
    |> assign(:notifications, notifications)
    |> assign(:watchlists, watchlists)
    |> assign(:module_types, module_types)
    |> assign(:unread_count, count_unread(notifications))
  end

  # ── URL ───────────────────────────────────────────────────────────

  @impl true
  def handle_params(_params, _uri, %{assigns: %{user_id: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    show = Map.get(params, "show", "all")
    show = if show in ["all", "unread", "read"], do: show, else: "all"

    wl_id = empty_to_nil(params["wl"])

    notifications =
      if wl_id != socket.assigns.watchlist_filter do
        load_notifications(socket.assigns.user_id, wl_id)
      else
        socket.assigns.notifications
      end

    socket =
      socket
      |> assign(:show_filter, show)
      |> assign(:watchlist_filter, wl_id)
      |> assign(:notifications, notifications)
      |> assign(:unread_count, count_unread(notifications))

    cond do
      params["new"] == "1" ->
        seeded = seed_form_from_params(params, socket.assigns.module_types)

        {:noreply,
         socket
         |> assign(:drawer_mode, :new)
         |> assign(:editing_watchlist, nil)
         |> assign(:form_data, seeded)
         |> assign(:form_errors, %{})}

      wl_id && params["edit"] == "1" ->
        case find_watchlist(socket.assigns.watchlists, wl_id) do
          nil ->
            {:noreply, push_patch(socket, to: ~p"/watch")}

          watchlist ->
            {:noreply,
             socket
             |> assign(:drawer_mode, :edit)
             |> assign(:editing_watchlist, watchlist)
             |> assign(:form_data, watchlist_to_form_data(watchlist))
             |> assign(:form_errors, %{})}
        end

      true ->
        {:noreply,
         socket
         |> assign(:drawer_mode, nil)
         |> assign(:editing_watchlist, nil)}
    end
  end

  # ── Selection / nav ───────────────────────────────────────────────

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/watch?wl=#{id}")}
  end

  def handle_event("new", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/watch?new=1")}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/watch?wl=#{id}&edit=1")}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/watch")}
  end

  # ── Form lifecycle ────────────────────────────────────────────────

  def handle_event("validate", %{"watchlist" => params}, socket) do
    form_data =
      parse_form_params(params, socket.assigns.form_data, socket.assigns.module_types)

    errors = validate_form(form_data)

    {:noreply,
     socket
     |> assign(:form_data, form_data)
     |> assign(:form_errors, errors)}
  end

  def handle_event("save", %{"watchlist" => params}, socket) do
    form_data =
      parse_form_params(params, socket.assigns.form_data, socket.assigns.module_types)

    errors = validate_form(form_data)

    if Enum.empty?(errors) do
      case socket.assigns.editing_watchlist do
        nil -> create_watchlist(socket, form_data)
        watchlist -> update_watchlist(socket, watchlist, form_data)
      end
    else
      {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  # ── Pause / Resume ────────────────────────────────────────────────

  def handle_event("toggle_notifications", %{"id" => id}, socket) do
    case find_watchlist(socket.assigns.watchlists, id) do
      nil ->
        {:noreply, socket}

      watchlist ->
        case Ash.update(watchlist, %{}, action: :toggle_notifications) do
          {:ok, updated} ->
            {:noreply,
             assign(
               socket,
               :watchlists,
               update_watchlist_in_list(socket.assigns.watchlists, updated)
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle notifications")}
        end
    end
  end

  # ── Watchlist delete (inline confirm) ─────────────────────────────

  def handle_event("delete_watchlist", %{"id" => id}, socket) do
    Process.send_after(self(), {:cancel_delete, :watchlist, id}, 6_000)
    {:noreply, assign(socket, :confirming_delete_watchlist_id, id)}
  end

  def handle_event("cancel_delete_watchlist", _params, socket) do
    {:noreply, assign(socket, :confirming_delete_watchlist_id, nil)}
  end

  def handle_event("confirm_delete_watchlist", %{"id" => id}, socket) do
    case find_watchlist(socket.assigns.watchlists, id) do
      nil ->
        {:noreply, assign(socket, :confirming_delete_watchlist_id, nil)}

      watchlist ->
        case Ash.destroy(watchlist) do
          :ok ->
            watchlists = Enum.reject(socket.assigns.watchlists, &(&1.id == id))

            {:noreply,
             socket
             |> assign(:watchlists, watchlists)
             |> assign(:confirming_delete_watchlist_id, nil)}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:confirming_delete_watchlist_id, nil)
             |> put_flash(:error, "Failed to delete watchlist")}
        end
    end
  end

  # ── Notification delete (inline confirm) ──────────────────────────

  def handle_event("delete_notification", %{"id" => id}, socket) do
    Process.send_after(self(), {:cancel_delete, :notification, id}, 6_000)
    {:noreply, assign(socket, :confirming_delete_notification_id, id)}
  end

  def handle_event("cancel_delete_notification", _params, socket) do
    {:noreply, assign(socket, :confirming_delete_notification_id, nil)}
  end

  def handle_event("confirm_delete_notification", %{"id" => id}, socket) do
    case find_notification(socket.assigns.notifications, id) do
      nil ->
        {:noreply, assign(socket, :confirming_delete_notification_id, nil)}

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
             |> assign(:confirming_delete_notification_id, nil)}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:confirming_delete_notification_id, nil)
             |> put_flash(:error, "Failed to delete notification")}
        end
    end
  end

  # ── Notification row toggle (also marks read) ─────────────────────

  def handle_event("toggle_row", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply,
       socket
       |> assign(:expanded_id, nil)
       |> assign(:confirming_delete_notification_id, nil)}
    else
      socket =
        socket
        |> assign(:expanded_id, id)
        |> assign(:confirming_delete_notification_id, nil)

      case find_notification(socket.assigns.notifications, id) do
        %{read: false} = n -> mark_read_now(socket, n)
        _ -> {:noreply, socket}
      end
    end
  end

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

  # ── Filters ───────────────────────────────────────────────────────

  def handle_event("filter", %{"show" => show}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/watch?#{filter_params(show, socket.assigns.watchlist_filter)}"
     )}
  end

  def handle_event("filter_watchlist", %{"watchlist" => raw}, socket) do
    wid = empty_to_nil(raw)

    {:noreply,
     push_patch(socket, to: ~p"/watch?#{filter_params(socket.assigns.show_filter, wid)}")}
  end

  def handle_event("clear_watchlist_filter", _params, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/watch?#{filter_params(socket.assigns.show_filter, nil)}")}
  end

  # ── Attribute repeater ────────────────────────────────────────────

  def handle_event("add_important_attr", _params, socket) do
    fd = socket.assigns.form_data
    next = fd.important_attributes ++ [%{name: "", value: ""}]
    {:noreply, assign(socket, :form_data, %{fd | important_attributes: next})}
  end

  def handle_event("remove_important_attr", %{"index" => index}, socket) do
    fd = socket.assigns.form_data

    case parse_list_index(index, fd.important_attributes) do
      :error ->
        {:noreply, socket}

      {:ok, idx} ->
        next = List.delete_at(fd.important_attributes, idx)
        {:noreply, assign(socket, :form_data, %{fd | important_attributes: next})}
    end
  end

  def handle_event("add_unimportant_attr", _params, socket) do
    fd = socket.assigns.form_data
    next = fd.unimportant_attributes ++ [%{name: "", value: ""}]
    {:noreply, assign(socket, :form_data, %{fd | unimportant_attributes: next})}
  end

  def handle_event("remove_unimportant_attr", %{"index" => index}, socket) do
    fd = socket.assigns.form_data

    case parse_list_index(index, fd.unimportant_attributes) do
      :error ->
        {:noreply, socket}

      {:ok, idx} ->
        next = List.delete_at(fd.unimportant_attributes, idx)
        {:noreply, assign(socket, :form_data, %{fd | unimportant_attributes: next})}
    end
  end

  # ── Keyboard ──────────────────────────────────────────────────────

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    cond do
      socket.assigns.confirming_delete_watchlist_id ->
        {:noreply, assign(socket, :confirming_delete_watchlist_id, nil)}

      socket.assigns.confirming_delete_notification_id ->
        {:noreply, assign(socket, :confirming_delete_notification_id, nil)}

      socket.assigns.drawer_mode in [:edit, :new] ->
        {:noreply, push_patch(socket, to: ~p"/watch")}

      socket.assigns.expanded_id ->
        {:noreply, assign(socket, :expanded_id, nil)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  # Parse a phx-value-index sent from the client into a valid 0-based
  # list index, or :error. Defends against malformed or out-of-range
  # values reaching List.delete_at.
  defp parse_list_index(raw, list) when is_binary(raw) do
    with {idx, ""} <- Integer.parse(raw),
         true <- idx >= 0 and idx < length(list) do
      {:ok, idx}
    else
      _ -> :error
    end
  end

  defp parse_list_index(_, _), do: :error

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

  # ── PubSub & timers ───────────────────────────────────────────────

  @impl true
  def handle_info(:refresh, socket) do
    if socket.assigns.user_id do
      {:noreply, load_data(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:new_notification, payload}, socket) do
    notifications =
      load_notifications(socket.assigns.user_id, socket.assigns.watchlist_filter)

    watchlists = load_watchlists(socket.assigns.user_id)
    Process.send_after(self(), :clear_flash_id, 1000)

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:watchlists, watchlists)
     |> assign(:unread_count, count_unread(notifications))
     |> assign(:flash_id, payload[:id] || payload["id"])}
  end

  def handle_info({:watchlist_update, _payload}, socket) do
    watchlists = load_watchlists(socket.assigns.user_id)
    {:noreply, assign(socket, :watchlists, watchlists)}
  end

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

  def handle_info(:all_notifications_read, socket) do
    notifications = Enum.map(socket.assigns.notifications, &%{&1 | read: true})

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, 0)}
  end

  def handle_info({:notification_deleted, notification_id}, socket) do
    notifications = Enum.reject(socket.assigns.notifications, &(&1.id == notification_id))

    expanded =
      if socket.assigns.expanded_id == notification_id,
        do: nil,
        else: socket.assigns.expanded_id

    {:noreply,
     socket
     |> assign(:notifications, notifications)
     |> assign(:unread_count, count_unread(notifications))
     |> assign(:expanded_id, expanded)}
  end

  def handle_info({:cancel_delete, :watchlist, id}, socket) do
    if socket.assigns.confirming_delete_watchlist_id == id do
      {:noreply, assign(socket, :confirming_delete_watchlist_id, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:cancel_delete, :notification, id}, socket) do
    if socket.assigns.confirming_delete_notification_id == id do
      {:noreply, assign(socket, :confirming_delete_notification_id, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:clear_flash_id, socket) do
    {:noreply, assign(socket, :flash_id, nil)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ── Data ──────────────────────────────────────────────────────────

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

  defp load_watchlists(nil), do: []

  defp load_watchlists(user_id) do
    case Ash.read(Watchlist, action: :for_user, args: %{user_id: user_id}) do
      {:ok, watchlists} -> watchlists
      {:error, _} -> []
    end
  end

  defp load_module_types do
    case Ash.read(ModuleType) do
      {:ok, types} -> Enum.sort_by(types, & &1.name)
      {:error, _} -> []
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(v), do: v

  defp filter_params(show, nil), do: %{"show" => show}
  defp filter_params(show, wid), do: %{"show" => show, "wl" => wid}

  defp find_watchlist(watchlists, id), do: Enum.find(watchlists, &(&1.id == id))
  defp find_notification(notifications, id), do: Enum.find(notifications, &(&1.id == id))

  defp update_watchlist_in_list(watchlists, updated) do
    Enum.map(watchlists, fn w -> if w.id == updated.id, do: updated, else: w end)
  end

  defp update_notification_in_list(notifications, updated) do
    Enum.map(notifications, fn n -> if n.id == updated.id, do: updated, else: n end)
  end

  defp count_unread(notifications), do: Enum.count(notifications, &(not &1.read))

  defp filtered_notifications(notifications, "all"), do: notifications

  defp filtered_notifications(notifications, "unread"),
    do: Enum.filter(notifications, &(not &1.read))

  defp filtered_notifications(notifications, "read"), do: Enum.filter(notifications, & &1.read)

  defp default_form_data do
    %{
      name: "",
      module_type_id: nil,
      module_type_name: nil,
      important_attributes: [],
      unimportant_attributes: [],
      price_threshold: nil,
      min_score: nil,
      notifications_enabled: true
    }
  end

  defp seed_form_from_params(params, module_types) do
    type_id = parse_integer(params["type_id"])
    type = type_id && Enum.find(module_types, &(&1.eve_type_id == type_id))

    %{
      default_form_data()
      | name: (type && "#{type.name} watch") || "",
        module_type_id: type_id,
        module_type_name: type && type.name,
        price_threshold: parse_decimal(params["max_price"]),
        min_score: parse_float_opt(params["min_score"])
    }
  end

  defp watchlist_to_form_data(watchlist) do
    %{
      name: watchlist.name,
      module_type_id: watchlist.module_type_id,
      module_type_name: watchlist.module_type_name,
      important_attributes: map_to_attr_list(watchlist.important_attributes),
      unimportant_attributes: map_to_attr_list(watchlist.unimportant_attributes),
      price_threshold: watchlist.price_threshold,
      min_score: watchlist.min_score,
      notifications_enabled: watchlist.notifications_enabled
    }
  end

  defp map_to_attr_list(nil), do: []
  defp map_to_attr_list(map) when map_size(map) == 0, do: []

  defp map_to_attr_list(map) do
    Enum.map(map, fn {name, value} -> %{name: name, value: value} end)
  end

  defp parse_form_params(params, current_data, module_types) do
    module_type = find_module_type_by_id(params["module_type_id"], module_types)

    %{
      name: params["name"] || "",
      module_type_id: parse_integer(params["module_type_id"]),
      module_type_name: module_type && module_type.name,
      important_attributes:
        parse_attributes(params["important_attributes"] || current_data.important_attributes),
      unimportant_attributes:
        parse_attributes(params["unimportant_attributes"] || current_data.unimportant_attributes),
      price_threshold: parse_decimal(params["price_threshold"]),
      min_score: parse_float_opt(params["min_score"]),
      notifications_enabled: params["notifications_enabled"] == "true"
    }
  end

  defp find_module_type_by_id(nil, _), do: nil
  defp find_module_type_by_id("", _), do: nil

  defp find_module_type_by_id(id, module_types) do
    case Integer.parse(to_string(id)) do
      {type_id, _} -> Enum.find(module_types, &(&1.eve_type_id == type_id))
      :error -> nil
    end
  end

  defp parse_attributes(attrs) when is_list(attrs), do: attrs

  defp parse_attributes(attrs) when is_map(attrs) do
    attrs
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {_idx, attr} ->
      %{name: attr["name"] || "", value: parse_attr_value(attr["value"])}
    end)
  end

  defp parse_attributes(_), do: []

  defp parse_attr_value(nil), do: ""
  defp parse_attr_value(value) when is_binary(value), do: value
  defp parse_attr_value(value), do: to_string(value)

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_), do: nil

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(_), do: nil

  defp parse_float_opt(nil), do: nil
  defp parse_float_opt(""), do: nil

  defp parse_float_opt(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float_opt(_), do: nil

  defp validate_form(form_data) do
    errors = %{}

    errors =
      if String.trim(form_data.name) == "",
        do: Map.put(errors, :name, "Name is required"),
        else: errors

    errors =
      if is_nil(form_data.module_type_id),
        do: Map.put(errors, :module_type_id, "Module type is required"),
        else: errors

    errors
  end

  defp create_watchlist(socket, form_data) do
    attrs = build_watchlist_attrs(form_data, socket.assigns.user_id)

    case Ash.create(Watchlist, attrs) do
      {:ok, watchlist} ->
        watchlists = [watchlist | socket.assigns.watchlists]

        {:noreply,
         socket
         |> assign(:watchlists, watchlists)
         |> push_patch(to: ~p"/watch")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to create watchlist: #{inspect(error)}")}
    end
  end

  defp update_watchlist(socket, watchlist, form_data) do
    attrs = %{
      name: form_data.name,
      important_attributes: attrs_list_to_map(form_data.important_attributes),
      unimportant_attributes: attrs_list_to_map(form_data.unimportant_attributes),
      price_threshold: form_data.price_threshold,
      min_score: form_data.min_score,
      notifications_enabled: form_data.notifications_enabled
    }

    case Ash.update(watchlist, attrs) do
      {:ok, updated} ->
        watchlists = update_watchlist_in_list(socket.assigns.watchlists, updated)

        {:noreply,
         socket
         |> assign(:watchlists, watchlists)
         |> push_patch(to: ~p"/watch")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to update watchlist: #{inspect(error)}")}
    end
  end

  defp build_watchlist_attrs(form_data, user_id) do
    %{
      user_id: user_id,
      name: form_data.name,
      module_type_id: form_data.module_type_id,
      module_type_name: form_data.module_type_name,
      important_attributes: attrs_list_to_map(form_data.important_attributes),
      unimportant_attributes: attrs_list_to_map(form_data.unimportant_attributes),
      price_threshold: form_data.price_threshold,
      min_score: form_data.min_score,
      notifications_enabled: form_data.notifications_enabled
    }
  end

  defp attrs_list_to_map(attrs) when is_list(attrs) do
    attrs
    |> Enum.reject(fn attr -> String.trim(attr.name || attr[:name] || "") == "" end)
    |> Enum.into(%{}, fn attr ->
      name = attr.name || attr[:name]
      value = attr.value || attr[:value]
      {name, parse_float_opt(value) || value}
    end)
  end

  defp attrs_list_to_map(_), do: %{}

  defp watchlist_name_for(watchlists, %{watchlist_id: id}) when not is_nil(id) do
    case Enum.find(watchlists, &(&1.id == id)) do
      nil -> nil
      w -> w.name
    end
  end

  defp watchlist_name_for(_, _), do: nil

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @user_id do %>
      <.signed_in_view
        notifications={@notifications}
        watchlists={@watchlists}
        module_types={@module_types}
        unread_count={@unread_count}
        show_filter={@show_filter}
        watchlist_filter={@watchlist_filter}
        expanded_id={@expanded_id}
        flash_id={@flash_id}
        drawer_mode={@drawer_mode}
        editing_watchlist={@editing_watchlist}
        form_data={@form_data}
        form_errors={@form_errors}
        confirming_delete_watchlist_id={@confirming_delete_watchlist_id}
        confirming_delete_notification_id={@confirming_delete_notification_id}
      />
    <% else %>
      <.signed_out_view />
    <% end %>
    """
  end

  attr :notifications, :list, required: true
  attr :watchlists, :list, required: true
  attr :module_types, :list, required: true
  attr :unread_count, :integer, required: true
  attr :show_filter, :string, required: true
  attr :watchlist_filter, :any, required: true
  attr :expanded_id, :any, required: true
  attr :flash_id, :any, required: true
  attr :drawer_mode, :any, required: true
  attr :editing_watchlist, :any, required: true
  attr :form_data, :map, required: true
  attr :form_errors, :map, required: true
  attr :confirming_delete_watchlist_id, :any, required: true
  attr :confirming_delete_notification_id, :any, required: true

  defp signed_in_view(assigns) do
    filtered = filtered_notifications(assigns.notifications, assigns.show_filter)
    {active, paused} = partition_watchlists(assigns.watchlists)

    assigns =
      assigns
      |> assign(:filtered_notifications, filtered)
      |> assign(:active_list, active)
      |> assign(:paused_list, paused)

    ~H"""
    <div id="watch-root" phx-window-keydown="keydown" phx-key="Escape">
      <header class="flex items-end justify-between gap-6 mb-6">
        <div>
          <span class="sidebar-kicker">Watch</span>
          <h1 class="text-display mt-3">Markets you're hunting</h1>
          <p class="text-body text-ink-3 mt-1">Matches as they arrive.</p>
        </div>
        <div>
          <button type="button" class="btn btn-primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New watchlist
          </button>
        </div>
      </header>

      <section class="panel mb-6">
        <div class="panel-header">
          <h2 class="text-[13px] font-semibold uppercase tracking-wider text-ink-3">
            Activity
          </h2>
          <div class="flex items-center gap-3">
            <div class="inline-flex items-center gap-1 p-1 border border-rule-1 rounded-md">
              <.show_chip filter="all" current={@show_filter} label="All" />
              <.show_chip filter="unread" current={@show_filter} label="Unread" />
              <.show_chip filter="read" current={@show_filter} label="Read" />
            </div>
            <%= if @unread_count > 0 do %>
              <span class="text-[12px] text-ink-3 tnum">
                {@unread_count} unread ·
                <button type="button" class="text-accent hover:underline" phx-click="mark_all_read">
                  Mark all read
                </button>
              </span>
            <% end %>
          </div>
        </div>

        <%= if @watchlist_filter do %>
          <div class="px-4 py-2 border-b border-rule-1 text-[12px] text-ink-3 flex items-center gap-2">
            Filtering by watchlist
            <button type="button" class="btn btn-sm btn-ghost" phx-click="clear_watchlist_filter">
              Clear
            </button>
          </div>
        <% end %>

        <%= if Enum.empty?(@filtered_notifications) do %>
          <div class="panel-body text-center text-ink-3 text-[13px] py-8">
            <%= cond do %>
              <% Enum.empty?(@notifications) -> %>
                No matches yet. New abyssal modules matching your watchlists will land here.
              <% @show_filter == "unread" -> %>
                No unread notifications. You're caught up.
              <% @show_filter == "read" -> %>
                No read notifications yet.
              <% true -> %>
                No matches.
            <% end %>
          </div>
        <% else %>
          <ul class="divide-y divide-rule-1">
            <%= for n <- @filtered_notifications do %>
              <.notification_row
                notification={n}
                watchlist_name={watchlist_name_for(@watchlists, n)}
                expanded={@expanded_id == n.id}
                flashing={@flash_id == n.id and not n.read}
                confirming={@confirming_delete_notification_id == n.id}
              />
            <% end %>
          </ul>
        <% end %>
      </section>

      <hr class="section-break" />

      <section>
        <header class="flex items-end justify-between gap-4 mb-4">
          <div>
            <h2 class="text-[15px] font-semibold text-ink-1">
              Your watchlists
              <span class="text-ink-4 font-normal">
                · {length(@active_list)} active<%= if Enum.any?(@paused_list) do %>
                  , {length(@paused_list)} paused
                <% end %>
              </span>
            </h2>
          </div>
        </header>

        <%= if Enum.empty?(@watchlists) do %>
          <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_320px]">
            <div class="panel">
              <div class="px-6 py-8">
                <h3 class="text-ink-1 text-[16px] font-semibold">
                  Save a search and we'll watch it for you.
                </h3>
                <p class="mt-2 text-ink-3 text-[13px] leading-relaxed">
                  A watchlist pings your Discord every time a fresh abyssal module shows up
                  matching your filters — score floor, max price, attribute mins / maxes.
                  No more refreshing Mutamarket every hour.
                </p>

                <div class="mt-5 grid gap-2.5" data-stagger>
                  <p class="text-[10px] uppercase tracking-wider text-ink-4 font-semibold">
                    Quick templates
                  </p>
                  <button
                    type="button"
                    phx-click="new"
                    class="watch-template"
                  >
                    <.icon name="hero-bolt" class="size-4 text-accent shrink-0 mt-0.5" />
                    <div class="text-left">
                      <p class="text-[13px] text-ink-1 font-medium">
                        Top 10/10 invul rolls under 500M
                      </p>
                      <p class="text-[11px] text-ink-4 mt-0.5">
                        High score floor, hard price ceiling
                      </p>
                    </div>
                  </button>
                  <button
                    type="button"
                    phx-click="new"
                    class="watch-template"
                  >
                    <.icon name="hero-currency-dollar" class="size-4 text-signal shrink-0 mt-0.5" />
                    <div class="text-left">
                      <p class="text-[13px] text-ink-1 font-medium">
                        Damage Control deals — score 0.7+
                      </p>
                      <p class="text-[11px] text-ink-4 mt-0.5">Catch underpriced rolls fast</p>
                    </div>
                  </button>
                  <button
                    type="button"
                    phx-click="new"
                    class="watch-template"
                  >
                    <.icon name="hero-cog-6-tooth" class="size-4 text-ink-2 shrink-0 mt-0.5" />
                    <div class="text-left">
                      <p class="text-[13px] text-ink-1 font-medium">Custom watchlist</p>
                      <p class="text-[11px] text-ink-4 mt-0.5">
                        Pick a module type, set your own thresholds
                      </p>
                    </div>
                  </button>
                </div>

                <div class="mt-6 flex items-center gap-3">
                  <button type="button" class="btn btn-primary" phx-click="new">
                    <.icon name="hero-plus" class="size-4" /> Create watchlist
                  </button>
                  <.link navigate={~p"/search"} class="btn btn-ghost">
                    Browse search first <.icon name="hero-arrow-right" class="size-4" />
                  </.link>
                </div>
              </div>
            </div>

            <%!-- Sample preview card on desktop only --%>
            <div class="hidden lg:block">
              <p class="text-[10px] uppercase tracking-wider text-ink-4 font-semibold mb-2">
                Sample
              </p>
              <div class="panel pointer-events-none select-none opacity-80">
                <div class="px-4 py-3 border-b border-rule-1">
                  <div class="flex items-start justify-between gap-2">
                    <div class="min-w-0 flex-1">
                      <h3 class="text-[14px] font-semibold text-ink-1 truncate">
                        Cheap 10/10 Invul
                      </h3>
                      <p class="text-[11px] text-ink-4 truncate mt-0.5">
                        Abyssal Adaptive Invulnerability Field II
                      </p>
                    </div>
                    <span class="pill pill-ready">
                      <span class="pill-glyph" aria-hidden="true">●</span>
                      <span>live</span>
                    </span>
                  </div>
                  <div class="mt-2.5 flex flex-wrap gap-1.5">
                    <span class="watch-chip">
                      <span class="watch-chip-key">≤</span>
                      <span class="watch-chip-val tnum">500,000,000</span>
                      <span class="watch-chip-unit">ISK</span>
                    </span>
                    <span class="watch-chip">
                      <span class="watch-chip-key">score ≥</span>
                      <span class="watch-chip-val tnum">0.85</span>
                    </span>
                  </div>
                </div>
                <div class="px-4 py-3 flex items-baseline gap-4">
                  <div class="flex-1 min-w-0">
                    <p class="text-[10px] uppercase tracking-wider text-ink-4 font-semibold leading-none">
                      Total matches
                    </p>
                    <p class="mt-1 text-[22px] tnum leading-none font-mono text-ink-1">7</p>
                  </div>
                  <div class="text-right text-[11px] text-ink-3 leading-snug">
                    <p>Checked <span class="tnum">2m ago</span></p>
                    <p class="text-ink-4 mt-0.5">
                      <.icon name="hero-bell-alert" class="size-3 inline -mt-0.5" />
                      <span class="ml-0.5">Discord</span>
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for w <- @active_list ++ @paused_list do %>
              <.watchlist_card
                watchlist={w}
                confirming={@confirming_delete_watchlist_id == w.id}
              />
            <% end %>
          </div>
        <% end %>
      </section>

      <%= if @drawer_mode in [:new, :edit] do %>
        <div class="drawer-scrim" phx-click="cancel_form" aria-hidden="true"></div>
        <aside class="drawer" role="dialog" aria-label="Watchlist form">
          <div class="drawer-header">
            <h2 class="text-[15px] font-semibold text-ink-1">
              {if @drawer_mode == :new, do: "New watchlist", else: "Edit watchlist"}
            </h2>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="cancel_form"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <.watchlist_form
            form_data={@form_data}
            form_errors={@form_errors}
            module_types={@module_types}
            mode={@drawer_mode}
          />
        </aside>
      <% end %>
    </div>
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

  attr :filter, :string, required: true
  attr :current, :string, required: true
  attr :label, :string, required: true

  defp show_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-show={@filter}
      class={[
        "px-2.5 py-1 text-[12px] rounded-sm transition-colors",
        @current == @filter && "bg-surface-3 text-ink-1",
        @current != @filter && "text-ink-3 hover:text-ink-1 hover:bg-surface-2"
      ]}
      aria-pressed={@current == @filter}
    >
      {@label}
    </button>
    """
  end

  attr :notification, :any, required: true
  attr :watchlist_name, :any, required: true
  attr :expanded, :boolean, required: true
  attr :flashing, :boolean, required: true
  attr :confirming, :boolean, required: true

  defp notification_row(assigns) do
    contract_url =
      if assigns.notification.module_external_id,
        do: @mutamarket_module_url <> assigns.notification.module_external_id,
        else: nil

    assigns = assign(assigns, :contract_url, contract_url)

    ~H"""
    <li id={"row-#{@notification.id}"}>
      <button
        type="button"
        phx-click="toggle_row"
        phx-value-id={@notification.id}
        class={[
          "w-full flex items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-surface-2",
          @expanded && "bg-surface-2"
        ]}
      >
        <span class={[
          "text-[10px] leading-none",
          not @notification.read && "text-accent",
          @notification.read && "text-ink-4",
          @flashing && "animate-glyph-flash"
        ]}>
          {if @notification.read, do: "○", else: "●"}
        </span>
        <span class="flex-1 min-w-0">
          <span class={[
            "block text-[13px] truncate",
            not @notification.read && "text-ink-1 font-medium",
            @notification.read && "text-ink-2"
          ]}>
            {@notification.module_name || "Unknown module"}
          </span>
          <span class="block text-[11px] text-ink-4 truncate">
            {@watchlist_name || "—"} · score {format_score(@notification.module_score)} · {format_price_plain(
              @notification.module_price
            )} ISK
          </span>
        </span>
        <span class="text-[11px] text-ink-3 tnum shrink-0">
          {time_ago(@notification.sent_at)}
        </span>
      </button>

      <%= if @expanded do %>
        <div class="px-4 pb-4 bg-surface-2 border-t border-rule-1">
          <div class="flex items-center gap-2 flex-wrap pt-3">
            <a
              :if={@contract_url}
              href={@contract_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-sm btn-primary"
            >
              View on Mutamarket <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
            </a>

            <.link
              :if={@notification.watchlist_id}
              patch={~p"/watch?wl=#{@notification.watchlist_id}"}
              class="btn btn-sm"
            >
              Watchlist: {@watchlist_name || "—"}
            </.link>

            <span class="flex-1"></span>

            <%= if @confirming do %>
              <span class="text-[12px] text-ink-3 mr-1">Delete this notification?</span>
              <button
                type="button"
                class="btn btn-sm btn-danger"
                phx-click="confirm_delete_notification"
                phx-value-id={@notification.id}
              >
                Confirm
              </button>
              <button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="cancel_delete_notification"
              >
                Cancel
              </button>
            <% else %>
              <button
                type="button"
                class="btn btn-sm btn-ghost btn-danger"
                phx-click="delete_notification"
                phx-value-id={@notification.id}
              >
                Delete
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </li>
    """
  end

  attr :watchlist, :any, required: true
  attr :confirming, :boolean, required: true

  defp watchlist_card(assigns) do
    important_count = map_size(assigns.watchlist.important_attributes || %{})
    unimportant_count = map_size(assigns.watchlist.unimportant_attributes || %{})
    has_price = not is_nil(assigns.watchlist.price_threshold)
    has_score = not is_nil(assigns.watchlist.min_score)
    is_paused = not assigns.watchlist.notifications_enabled

    assigns =
      assigns
      |> assign(:important_count, important_count)
      |> assign(:unimportant_count, unimportant_count)
      |> assign(:has_price, has_price)
      |> assign(:has_score, has_score)
      |> assign(:is_paused, is_paused)

    ~H"""
    <div class={["panel", @is_paused && "opacity-75"]}>
      <div class="px-4 py-3 border-b border-rule-1">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0 flex-1">
            <h3 class="text-[14px] font-semibold text-ink-1 truncate">{@watchlist.name}</h3>
            <p class="text-[11px] text-ink-4 truncate mt-0.5">{@watchlist.module_type_name}</p>
          </div>
          <%= if @watchlist.notifications_enabled do %>
            <span class="pill pill-ready" title="Notifications active">
              <span class="pill-glyph" aria-hidden="true">●</span>
              <span>live</span>
            </span>
          <% else %>
            <span class="pill pill-idle" title="Notifications paused">
              <span class="pill-glyph" aria-hidden="true">○</span>
              <span>paused</span>
            </span>
          <% end %>
        </div>

        <%!-- Criteria chips: what this watchlist is actually watching for --%>
        <div
          :if={@has_price or @has_score or @important_count > 0 or @unimportant_count > 0}
          class="mt-2.5 flex flex-wrap gap-1.5"
        >
          <span :if={@has_price} class="watch-chip">
            <span class="watch-chip-key">≤</span>
            <span class="watch-chip-val tnum">{format_price_plain(@watchlist.price_threshold)}</span>
            <span class="watch-chip-unit">ISK</span>
          </span>
          <span :if={@has_score} class="watch-chip">
            <span class="watch-chip-key">score ≥</span>
            <span class="watch-chip-val tnum">{format_score(@watchlist.min_score)}</span>
          </span>
          <span :if={@important_count > 0} class="watch-chip" title="Required attribute floors">
            <.icon name="hero-arrow-trending-up" class="size-3" />
            <span class="watch-chip-val">{@important_count}</span>
            <span class="watch-chip-unit">{pluralize(@important_count, "min", "mins")}</span>
          </span>
          <span :if={@unimportant_count > 0} class="watch-chip" title="Attribute ceilings">
            <.icon name="hero-arrow-trending-down" class="size-3" />
            <span class="watch-chip-val">{@unimportant_count}</span>
            <span class="watch-chip-unit">{pluralize(@unimportant_count, "max", "maxes")}</span>
          </span>
        </div>
      </div>

      <%!-- Stats row: match count is the hero number --%>
      <div class="px-4 py-3 flex items-baseline gap-4">
        <div class="flex-1 min-w-0">
          <p class="text-[10px] uppercase tracking-wider text-ink-4 font-semibold leading-none">
            Total matches
          </p>
          <p class={[
            "mt-1 text-[22px] tnum leading-none font-mono",
            (@watchlist.match_count || 0) > 0 && "text-ink-1",
            (@watchlist.match_count || 0) == 0 && "text-ink-3"
          ]}>
            {@watchlist.match_count || 0}
          </p>
        </div>
        <div class="text-right text-[11px] text-ink-3 leading-snug">
          <%= if @watchlist.last_checked_at do %>
            <p>Checked <span class="tnum">{time_ago(@watchlist.last_checked_at)}</span></p>
          <% else %>
            <p class="italic">Not yet checked</p>
          <% end %>
          <p class="text-ink-4 mt-0.5">
            <.icon name="hero-bell-alert" class="size-3 inline -mt-0.5" />
            <span class="ml-0.5">Discord</span>
          </p>
        </div>
      </div>

      <footer class="px-4 py-2 flex items-center gap-2 flex-wrap border-t border-rule-1">
        <button
          type="button"
          class="btn btn-sm"
          phx-click="edit"
          phx-value-id={@watchlist.id}
        >
          Edit
        </button>
        <button
          type="button"
          class="btn btn-sm"
          phx-click="toggle_notifications"
          phx-value-id={@watchlist.id}
        >
          {if @watchlist.notifications_enabled, do: "Pause", else: "Resume"}
        </button>
        <span class="flex-1"></span>
        <%= if @confirming do %>
          <button
            type="button"
            class="btn btn-sm btn-danger"
            phx-click="confirm_delete_watchlist"
            phx-value-id={@watchlist.id}
          >
            Confirm
          </button>
          <button
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="cancel_delete_watchlist"
          >
            Cancel
          </button>
        <% else %>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-danger"
            phx-click="delete_watchlist"
            phx-value-id={@watchlist.id}
          >
            Delete
          </button>
        <% end %>
      </footer>
    </div>
    """
  end

  attr :form_data, :map, required: true
  attr :form_errors, :map, required: true
  attr :module_types, :list, required: true
  attr :mode, :atom, required: true

  defp watchlist_form(assigns) do
    ~H"""
    <form phx-submit="save" phx-change="validate" class="drawer-body space-y-5">
      <input type="hidden" name="watchlist[notifications_enabled]" value="false" />

      <div class="field">
        <label class="field-label" for="watchlist-name">Name</label>
        <input
          id="watchlist-name"
          type="text"
          name="watchlist[name]"
          class={["input", @form_errors[:name] && "input-error"]}
          value={@form_data.name}
          placeholder="My watch"
          phx-debounce="200"
        />
        <p :if={@form_errors[:name]} class="field-error">
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
          <span>{@form_errors[:name]}</span>
        </p>
      </div>

      <div class="field">
        <label class="field-label" for="watchlist-type">Module type</label>
        <input
          :if={@mode == :edit}
          type="hidden"
          name="watchlist[module_type_id]"
          value={@form_data.module_type_id}
        />
        <select
          id="watchlist-type"
          name={
            if @mode == :edit, do: "watchlist[_module_type_id]", else: "watchlist[module_type_id]"
          }
          class={["select", @form_errors[:module_type_id] && "select-error"]}
          disabled={@mode == :edit}
        >
          <option value="">Select a type</option>
          <%= for type <- @module_types do %>
            <option
              value={type.eve_type_id}
              selected={@form_data.module_type_id == type.eve_type_id}
            >
              {type.name} ({type.category})
            </option>
          <% end %>
        </select>
        <p :if={@form_errors[:module_type_id]} class="field-error">
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
          <span>{@form_errors[:module_type_id]}</span>
        </p>
        <p :if={@mode == :edit} class="text-[11px] text-ink-4 mt-1">
          Module type is fixed once created.
        </p>
      </div>

      <div class="grid grid-cols-2 gap-3">
        <div class="field">
          <label class="field-label" for="watchlist-price">Max price (ISK)</label>
          <input
            id="watchlist-price"
            type="number"
            name="watchlist[price_threshold]"
            class="input tnum"
            value={@form_data.price_threshold}
            placeholder="No limit"
            phx-debounce="300"
          />
        </div>
        <div class="field">
          <label class="field-label" for="watchlist-score">Min score</label>
          <input
            id="watchlist-score"
            type="number"
            name="watchlist[min_score]"
            class="input tnum"
            value={@form_data.min_score}
            step="0.05"
            min="0"
            max="1"
            placeholder="No limit"
            phx-debounce="300"
          />
        </div>
      </div>

      <.attribute_repeater
        title="Important attributes"
        subtitle="(minimum)"
        comparator="≥"
        field_name="important_attributes"
        attrs={@form_data.important_attributes}
        add_event="add_important_attr"
        remove_event="remove_important_attr"
      />

      <.attribute_repeater
        title="Unimportant attributes"
        subtitle="(maximum)"
        comparator="≤"
        field_name="unimportant_attributes"
        attrs={@form_data.unimportant_attributes}
        add_event="add_unimportant_attr"
        remove_event="remove_unimportant_attr"
      />

      <div class="flex items-center gap-2">
        <input
          id="watchlist-notify"
          type="checkbox"
          name="watchlist[notifications_enabled]"
          class="checkbox"
          value="true"
          checked={@form_data.notifications_enabled}
        />
        <label for="watchlist-notify" class="text-[13px] text-ink-2 cursor-pointer">
          Notifications enabled
        </label>
      </div>

      <div class="drawer-footer">
        <button type="button" class="btn" phx-click="cancel_form">Cancel</button>
        <button type="submit" class="btn btn-primary">
          {if @mode == :new, do: "Create", else: "Save changes"}
        </button>
      </div>
    </form>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :comparator, :string, required: true
  attr :field_name, :string, required: true
  attr :attrs, :list, required: true
  attr :add_event, :string, required: true
  attr :remove_event, :string, required: true

  defp attribute_repeater(assigns) do
    ~H"""
    <div>
      <div class="flex items-baseline justify-between mb-2">
        <span class="field-label mb-0">
          {@title} <span class="text-ink-4 font-normal">{@subtitle}</span>
        </span>
        <button type="button" class="btn btn-sm btn-ghost" phx-click={@add_event}>
          <.icon name="hero-plus" class="size-4" /> Add
        </button>
      </div>

      <%= if Enum.empty?(@attrs) do %>
        <p class="text-[12px] text-ink-4">No thresholds set.</p>
      <% else %>
        <div class="space-y-1.5">
          <%= for {attr, idx} <- Enum.with_index(@attrs) do %>
            <div class="flex items-center gap-2">
              <input
                type="text"
                name={"watchlist[#{@field_name}][#{idx}][name]"}
                class="input input-sm flex-1"
                value={attr.name || attr[:name]}
                placeholder="Attribute name"
                phx-debounce="200"
              />
              <span class="text-[12px] text-ink-4 tnum w-4 text-center">{@comparator}</span>
              <input
                type="text"
                name={"watchlist[#{@field_name}][#{idx}][value]"}
                class="input input-sm w-24 tnum text-right"
                value={attr.value || attr[:value]}
                placeholder="Value"
                phx-debounce="200"
              />
              <button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click={@remove_event}
                phx-value-index={idx}
                aria-label="Remove"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp partition_watchlists(watchlists) do
    {active, paused} = Enum.split_with(watchlists, & &1.notifications_enabled)
    sorter = fn w -> {w.last_checked_at || ~U[1970-01-01 00:00:00Z], w.match_count || 0} end
    {Enum.sort_by(active, sorter, :desc), Enum.sort_by(paused, sorter, :desc)}
  end

  # ── Format ────────────────────────────────────────────────────────

  defp pluralize(1, s, _), do: s
  defp pluralize(_, _, p), do: p

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
