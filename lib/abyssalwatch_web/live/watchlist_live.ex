defmodule AbyssalwatchWeb.WatchlistLive do
  @moduledoc """
  Master-detail surface for managing watchlists.

  A 280px rail of watchlists on the left, a detail pane on the right.
  Detail pane defaults to read-only; Edit toggles to a form. New
  watchlists are created via `?action=new`. Selection is URL-driven via
  `?id=…`, so deep-links from Discord notifications resolve directly.

  See DESIGN.md and PRODUCT.md for the visual language.
  """
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Watchlists.{Watchlist, Notifier}
  alias Abyssalwatch.Market.ModuleType

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    user_id = user && user.id

    if connected?(socket) and user_id do
      Notifier.subscribe(user_id)
    end

    watchlists = load_watchlists(user_id)
    module_types = load_module_types()

    {:ok,
     socket
     |> assign(:user_id, user_id)
     |> assign(:watchlists, watchlists)
     |> assign(:module_types, module_types)
     |> assign(:selected_id, default_selected_id(watchlists))
     |> assign(:mode, :read)
     |> assign(:form_data, default_form_data())
     |> assign(:form_errors, %{})
     |> assign(:editing_watchlist, nil)
     |> assign(:confirming_delete_id, nil)}
  end

  # ── URL handling ───────────────────────────────────────────────────

  @impl true
  def handle_params(%{"action" => "new"} = params, _uri, socket) do
    seeded = seed_form_from_params(params, socket.assigns.module_types)

    {:noreply,
     socket
     |> assign(:mode, :new)
     |> assign(:editing_watchlist, nil)
     |> assign(:form_data, seeded)
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_params(%{"action" => "edit", "id" => id}, _uri, socket) do
    case find_watchlist(socket.assigns.watchlists, id) do
      nil ->
        {:noreply, push_patch(socket, to: ~p"/watchlists")}

      watchlist ->
        {:noreply,
         socket
         |> assign(:selected_id, watchlist.id)
         |> assign(:mode, :edit)
         |> assign(:editing_watchlist, watchlist)
         |> assign(:form_data, watchlist_to_form_data(watchlist))
         |> assign(:form_errors, %{})}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case find_watchlist(socket.assigns.watchlists, id) do
      nil -> {:noreply, push_patch(socket, to: ~p"/watchlists")}
      _ -> {:noreply, assign(socket, selected_id: id, mode: :read, confirming_delete_id: nil)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:mode, :read)
     |> assign(:editing_watchlist, nil)
     |> assign(:confirming_delete_id, nil)}
  end

  # ── Selection / mode ──────────────────────────────────────────────

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/watchlists?id=#{id}")}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/watchlists?action=new")}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/watchlists?action=edit&id=#{id}")}
  end

  @impl true
  def handle_event("cancel_form", _params, socket) do
    target =
      case socket.assigns.editing_watchlist do
        nil -> ~p"/watchlists"
        wl -> ~p"/watchlists?id=#{wl.id}"
      end

    {:noreply, push_patch(socket, to: target)}
  end

  # ── Form lifecycle ────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"watchlist" => params}, socket) do
    form_data = parse_form_params(params, socket.assigns.form_data)
    errors = validate_form(form_data)

    {:noreply,
     socket
     |> assign(:form_data, form_data)
     |> assign(:form_errors, errors)}
  end

  @impl true
  def handle_event("save", %{"watchlist" => params}, socket) do
    form_data = parse_form_params(params, socket.assigns.form_data)
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

  @impl true
  def handle_event("toggle_notifications", %{"id" => id}, socket) do
    case find_watchlist(socket.assigns.watchlists, id) do
      nil ->
        {:noreply, socket}

      watchlist ->
        case Ash.update(watchlist, %{}, action: :toggle_notifications) do
          {:ok, updated} ->
            {:noreply,
             assign(socket, :watchlists, update_watchlist_in_list(socket.assigns.watchlists, updated))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle notifications")}
        end
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
    case find_watchlist(socket.assigns.watchlists, id) do
      nil ->
        {:noreply, assign(socket, :confirming_delete_id, nil)}

      watchlist ->
        case Ash.destroy(watchlist) do
          :ok ->
            watchlists = Enum.reject(socket.assigns.watchlists, &(&1.id == id))
            next_id = default_selected_id(watchlists)

            target = if next_id, do: ~p"/watchlists?id=#{next_id}", else: ~p"/watchlists"

            {:noreply,
             socket
             |> assign(:watchlists, watchlists)
             |> assign(:confirming_delete_id, nil)
             |> push_patch(to: target)}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:confirming_delete_id, nil)
             |> put_flash(:error, "Failed to delete watchlist")}
        end
    end
  end

  # ── Attribute repeater (form) ─────────────────────────────────────

  @impl true
  def handle_event("add_important_attr", _params, socket) do
    fd = socket.assigns.form_data
    next = fd.important_attributes ++ [%{name: "", value: ""}]
    {:noreply, assign(socket, :form_data, %{fd | important_attributes: next})}
  end

  @impl true
  def handle_event("remove_important_attr", %{"index" => index}, socket) do
    {idx, _} = Integer.parse(index)
    fd = socket.assigns.form_data
    next = List.delete_at(fd.important_attributes, idx)
    {:noreply, assign(socket, :form_data, %{fd | important_attributes: next})}
  end

  @impl true
  def handle_event("add_unimportant_attr", _params, socket) do
    fd = socket.assigns.form_data
    next = fd.unimportant_attributes ++ [%{name: "", value: ""}]
    {:noreply, assign(socket, :form_data, %{fd | unimportant_attributes: next})}
  end

  @impl true
  def handle_event("remove_unimportant_attr", %{"index" => index}, socket) do
    {idx, _} = Integer.parse(index)
    fd = socket.assigns.form_data
    next = List.delete_at(fd.unimportant_attributes, idx)
    {:noreply, assign(socket, :form_data, %{fd | unimportant_attributes: next})}
  end

  # ── Keyboard ──────────────────────────────────────────────────────

  @impl true
  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    cond do
      socket.assigns.confirming_delete_id ->
        {:noreply, assign(socket, :confirming_delete_id, nil)}

      socket.assigns.mode in [:edit, :new] ->
        handle_event("cancel_form", %{}, socket)

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  # ── PubSub ────────────────────────────────────────────────────────

  @impl true
  def handle_info({:new_notification, _payload}, socket) do
    watchlists = load_watchlists(socket.assigns.user_id)
    {:noreply, assign(socket, :watchlists, watchlists)}
  end

  @impl true
  def handle_info({:watchlist_update, _payload}, socket) do
    watchlists = load_watchlists(socket.assigns.user_id)
    {:noreply, assign(socket, :watchlists, watchlists)}
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
  def handle_info(_, socket), do: {:noreply, socket}

  # ── Data ──────────────────────────────────────────────────────────

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

  defp default_selected_id([]), do: nil

  defp default_selected_id(watchlists) do
    watchlists
    |> Enum.sort_by(
      fn w -> {w.last_checked_at || ~U[1970-01-01 00:00:00Z], w.match_count || 0} end,
      :desc
    )
    |> List.first()
    |> case do
      nil -> nil
      w -> w.id
    end
  end

  defp find_watchlist(watchlists, id),
    do: Enum.find(watchlists, &(&1.id == id))

  defp update_watchlist_in_list(watchlists, updated) do
    Enum.map(watchlists, fn w -> if w.id == updated.id, do: updated, else: w end)
  end

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
      | name: type && "#{type.name} watch" || "",
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

  defp parse_form_params(params, current_data) do
    module_type = find_module_type_by_id(params["module_type_id"])

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

  defp find_module_type_by_id(nil), do: nil
  defp find_module_type_by_id(""), do: nil

  defp find_module_type_by_id(id) do
    case Integer.parse(to_string(id)) do
      {type_id, _} ->
        case Ash.read(ModuleType, action: :by_eve_type_id, args: %{eve_type_id: type_id}) do
          {:ok, [type | _]} -> type
          _ -> nil
        end

      :error ->
        nil
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
         |> push_patch(to: ~p"/watchlists?id=#{watchlist.id}")}

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
         |> push_patch(to: ~p"/watchlists?id=#{updated.id}")}

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

  # ── Sort + grouping ───────────────────────────────────────────────

  defp partition_watchlists(watchlists) do
    {active, paused} = Enum.split_with(watchlists, & &1.notifications_enabled)
    sorter = &recent_first/1
    {Enum.sort_by(active, sorter, :desc), Enum.sort_by(paused, sorter, :desc)}
  end

  defp recent_first(w),
    do: {w.last_checked_at || ~U[1970-01-01 00:00:00Z], w.match_count || 0}

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    {active, paused} = partition_watchlists(assigns.watchlists)

    selected =
      cond do
        assigns.mode == :new -> nil
        true -> find_watchlist(assigns.watchlists, assigns.selected_id)
      end

    assigns =
      assigns
      |> assign(:active_list, active)
      |> assign(:paused_list, paused)
      |> assign(:selected, selected)

    ~H"""
    <div
      id="watchlists-root"
      phx-window-keydown="keydown"
      phx-key="Escape"
    >
      <header class="flex items-end justify-between gap-6 pb-4 mb-6 border-b border-rule-1">
        <div>
          <h1 class="text-[22px] leading-[30px] font-semibold text-ink-1 tracking-tight">
            Watchlists
          </h1>
          <p class="mt-1 text-[13px] text-ink-3">
            <%= cond do %>
              <% Enum.empty?(@watchlists) -> %>
                Save searches you want notified about.
              <% true -> %>
                <span class="tnum">{length(@watchlists)}</span>
                {pluralize(length(@watchlists), "watchlist", "watchlists")}
                <span :if={Enum.any?(@paused_list)} class="text-ink-4">
                  · {length(@paused_list)} paused
                </span>
            <% end %>
          </p>
        </div>
      </header>

      <%= if Enum.empty?(@watchlists) do %>
        <.empty_state />
      <% else %>
        <div class="grid gap-6 lg:grid-cols-[280px_minmax(0,1fr)] lg:gap-8">
          <.rail
            active_list={@active_list}
            paused_list={@paused_list}
            selected_id={@selected_id}
            mode={@mode}
          />

          <div class="min-w-0">
            <%= cond do %>
              <% @mode in [:edit, :new] -> %>
                <.watchlist_form
                  form_data={@form_data}
                  form_errors={@form_errors}
                  module_types={@module_types}
                  mode={@mode}
                />
              <% @selected -> %>
                <.detail_pane
                  watchlist={@selected}
                  confirming_delete_id={@confirming_delete_id}
                />
              <% true -> %>
                <.detail_placeholder />
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp pluralize(1, s, _), do: s
  defp pluralize(_, _, p), do: p

  # ── Empty state ───────────────────────────────────────────────────

  defp empty_state(assigns) do
    ~H"""
    <div class="panel max-w-2xl mx-auto">
      <div class="px-8 py-12 text-center">
        <p class="text-ink-1 text-[15px]">No watchlists yet.</p>
        <p class="mt-1.5 text-ink-3 text-[13px] leading-relaxed">
          Save a search you want notified about, or start fresh.
        </p>
        <div class="mt-6 flex items-center justify-center gap-3">
          <button type="button" class="btn btn-primary" phx-click="new">
            Create your first watchlist
          </button>
          <.link navigate={~p"/search"} class="btn btn-ghost">
            Browse search
            <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # ── Rail ──────────────────────────────────────────────────────────

  attr :active_list, :list, required: true
  attr :paused_list, :list, required: true
  attr :selected_id, :any, required: true
  attr :mode, :atom, required: true

  defp rail(assigns) do
    ~H"""
    <aside class="panel self-start lg:sticky lg:top-[72px] max-h-[calc(100vh-72px)] flex flex-col overflow-hidden">
      <div class="panel-header">
        <h2 class="text-[13px] font-semibold uppercase tracking-wider text-ink-3">
          Watchlists
        </h2>
        <button
          type="button"
          class={[
            "btn btn-sm",
            @mode == :new && "btn-primary"
          ]}
          phx-click="new"
        >
          <.icon name="hero-plus" class="size-4" /> New
        </button>
      </div>

      <ul class="flex-1 overflow-y-auto py-1">
        <%= for watchlist <- @active_list do %>
          <.rail_row
            watchlist={watchlist}
            selected={@selected_id == watchlist.id and @mode != :new}
          />
        <% end %>

        <%= if Enum.any?(@paused_list) do %>
          <li class="px-4 pt-3 pb-1.5 text-[10px] uppercase tracking-wider text-ink-4 font-medium">
            Paused
          </li>
          <%= for watchlist <- @paused_list do %>
            <.rail_row
              watchlist={watchlist}
              selected={@selected_id == watchlist.id and @mode != :new}
            />
          <% end %>
        <% end %>
      </ul>
    </aside>
    """
  end

  attr :watchlist, :any, required: true
  attr :selected, :boolean, required: true

  defp rail_row(assigns) do
    paused = not assigns.watchlist.notifications_enabled
    assigns = assign(assigns, :paused, paused)

    ~H"""
    <li>
      <button
        type="button"
        phx-click="select"
        phx-value-id={@watchlist.id}
        class={[
          "w-full flex items-center gap-3 px-4 py-2.5 text-left transition-colors",
          @selected && "bg-surface-2",
          @selected && "shadow-[inset_2px_0_0_var(--accent)]",
          !@selected && "hover:bg-surface-2"
        ]}
      >
        <span
          class={[
            "text-[10px] leading-none mt-0.5",
            @paused && "text-ink-4",
            !@paused && "text-status-ready"
          ]}
          aria-hidden="true"
        >
          <%= if @paused, do: "○", else: "●" %>
        </span>
        <span class="flex-1 min-w-0">
          <span class={[
            "block text-[13px] truncate",
            @selected && "text-ink-1",
            !@selected && "text-ink-2"
          ]}>
            {@watchlist.name}
          </span>
          <span class="block text-[11px] text-ink-4 truncate">
            {@watchlist.module_type_name}
          </span>
        </span>
        <span class="text-[11px] text-ink-3 tnum shrink-0">
          {@watchlist.match_count || 0}
        </span>
      </button>
    </li>
    """
  end

  # ── Detail (read-only) ────────────────────────────────────────────

  attr :watchlist, :any, required: true
  attr :confirming_delete_id, :any, required: true

  defp detail_pane(assigns) do
    confirming = assigns.confirming_delete_id == assigns.watchlist.id
    assigns = assign(assigns, :confirming, confirming)

    ~H"""
    <div class="panel">
      <div class="px-5 py-4 border-b border-rule-1">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="flex items-center gap-2 flex-wrap">
              <h2 class="text-[17px] font-semibold text-ink-1 truncate">
                {@watchlist.name}
              </h2>
              <.status_pill enabled={@watchlist.notifications_enabled} />
            </div>
            <p class="mt-1 text-[12px] text-ink-3">
              {@watchlist.module_type_name}
            </p>
          </div>
        </div>

        <p class="mt-3 text-[12px] text-ink-3 tnum">
          <span class="text-ink-2">{@watchlist.match_count || 0}</span>
          {pluralize(@watchlist.match_count || 0, "match", "matches")}
          <%= if @watchlist.last_checked_at do %>
            <span class="text-ink-4">·</span> last checked {format_time_ago(@watchlist.last_checked_at)}
          <% end %>
        </p>
      </div>

      <section class="px-5 py-4 border-b border-rule-1">
        <h3 class="text-[11px] uppercase tracking-wider text-ink-3 font-medium mb-3">
          Filters
        </h3>
        <dl class="divide-y divide-rule-1 -mx-2">
          <.kv label="Max price">
            <span class="tnum"><%= format_price_isk(@watchlist.price_threshold) %></span>
          </.kv>
          <.kv label="Min score">
            <span class="tnum"><%= format_score(@watchlist.min_score) %></span>
          </.kv>
        </dl>
      </section>

      <section class="px-5 py-4 border-b border-rule-1">
        <h3 class="text-[11px] uppercase tracking-wider text-ink-3 font-medium mb-3">
          Important attributes
          <span class="text-ink-4 normal-case tracking-normal">(minimum)</span>
        </h3>
        <.attr_list attrs={@watchlist.important_attributes} comparator="≥" />
      </section>

      <section class="px-5 py-4 border-b border-rule-1">
        <h3 class="text-[11px] uppercase tracking-wider text-ink-3 font-medium mb-3">
          Unimportant attributes
          <span class="text-ink-4 normal-case tracking-normal">(maximum)</span>
        </h3>
        <.attr_list attrs={@watchlist.unimportant_attributes} comparator="≤" />
      </section>

      <footer class="px-5 py-3 flex items-center gap-2 flex-wrap">
        <button type="button" class="btn btn-primary btn-sm" phx-click="edit" phx-value-id={@watchlist.id}>
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
          <span class="text-[12px] text-ink-3 mr-1">Delete this watchlist?</span>
          <button
            type="button"
            class="btn btn-sm btn-danger"
            phx-click="confirm_delete"
            phx-value-id={@watchlist.id}
          >
            Confirm delete
          </button>
          <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel_delete">
            Cancel
          </button>
        <% else %>
          <button
            type="button"
            class="btn btn-sm btn-danger"
            phx-click="request_delete"
            phx-value-id={@watchlist.id}
          >
            Delete
          </button>
        <% end %>
      </footer>
    </div>
    """
  end

  attr :enabled, :boolean, required: true

  defp status_pill(assigns) do
    ~H"""
    <%= if @enabled do %>
      <span class="pill pill-ready">
        <span class="pill-glyph" aria-hidden="true">●</span>
        <span>Active</span>
      </span>
    <% else %>
      <span class="pill pill-idle">
        <span class="pill-glyph" aria-hidden="true">○</span>
        <span>Paused</span>
      </span>
    <% end %>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp kv(assigns) do
    ~H"""
    <div class="grid grid-cols-[160px_1fr] gap-4 px-2 py-2.5">
      <dt class="text-[12px] uppercase tracking-wider text-ink-3 font-medium">
        {@label}
      </dt>
      <dd class="text-ink-1 text-[13px]">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :attrs, :any, required: true
  attr :comparator, :string, required: true

  defp attr_list(assigns) do
    list =
      case assigns.attrs do
        nil -> []
        m when is_map(m) and map_size(m) == 0 -> []
        m when is_map(m) -> m |> Enum.sort_by(fn {k, _} -> k end)
        l when is_list(l) -> Enum.map(l, fn %{name: n, value: v} -> {n, v} end)
      end

    assigns = assign(assigns, :list, list)

    ~H"""
    <%= if Enum.empty?(@list) do %>
      <p class="text-[12px] text-ink-4">No attribute thresholds set.</p>
    <% else %>
      <ul class="space-y-1.5">
        <%= for {name, value} <- @list do %>
          <li class="flex items-baseline justify-between gap-3 text-[13px]">
            <span class="text-ink-2 truncate">{humanize_attr(name)}</span>
            <span class="tnum text-ink-1 shrink-0">
              {@comparator} {format_threshold_value(value)}
            </span>
          </li>
        <% end %>
      </ul>
    <% end %>
    """
  end

  defp detail_placeholder(assigns) do
    ~H"""
    <div class="panel">
      <div class="px-6 py-12 text-center text-ink-3 text-[13px]">
        Select a watchlist on the left.
      </div>
    </div>
    """
  end

  # ── Detail (form) ─────────────────────────────────────────────────

  attr :form_data, :map, required: true
  attr :form_errors, :map, required: true
  attr :module_types, :list, required: true
  attr :mode, :atom, required: true

  defp watchlist_form(assigns) do
    ~H"""
    <div class="panel">
      <div class="panel-header">
        <h2 class="text-[15px] font-semibold text-ink-1">
          <%= if @mode == :new, do: "New watchlist", else: "Edit watchlist" %>
        </h2>
        <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel_form">
          Cancel
        </button>
      </div>

      <form phx-submit="save" phx-change="validate" class="px-5 py-4 space-y-5">
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
            name={if @mode == :edit, do: "watchlist[_module_type_id]", else: "watchlist[module_type_id]"}
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
            Module type is fixed once created. Create a new watchlist to change it.
          </p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
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
            <label class="field-label" for="watchlist-score">Minimum score</label>
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

        <div class="flex items-center justify-end gap-2 pt-3 border-t border-rule-1">
          <button type="button" class="btn" phx-click="cancel_form">Cancel</button>
          <button type="submit" class="btn btn-primary">
            <%= if @mode == :new, do: "Create", else: "Save changes" %>
          </button>
        </div>
      </form>
    </div>
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
          {@title}
          <span class="text-ink-4 font-normal">{@subtitle}</span>
        </span>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@add_event}
        >
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

  # ── Format helpers ────────────────────────────────────────────────

  defp format_price_isk(nil), do: Phoenix.HTML.raw("<span class=\"text-ink-4\">No limit</span>")

  defp format_price_isk(%Decimal{} = price) do
    formatted =
      price
      |> Decimal.round(0)
      |> Decimal.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    formatted <> " ISK"
  end

  defp format_price_isk(price) when is_number(price) do
    format_price_isk(Decimal.new(round(price)))
  end

  defp format_price_isk(_), do: "—"

  defp format_score(nil), do: Phoenix.HTML.raw("<span class=\"text-ink-4\">No limit</span>")

  defp format_score(score) when is_number(score),
    do: :erlang.float_to_binary(score * 1.0, decimals: 2)

  defp format_score(_), do: "—"

  defp format_threshold_value(nil), do: "—"

  defp format_threshold_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp format_threshold_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_threshold_value(value) when is_binary(value), do: value
  defp format_threshold_value(value), do: to_string(value)

  defp humanize_attr(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize_attr(name), do: to_string(name)

  defp format_time_ago(nil), do: "never"

  defp format_time_ago(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp format_time_ago(_), do: "never"
end
