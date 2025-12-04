defmodule AbyssalwatchWeb.WatchlistLive do
  @moduledoc """
  LiveView for managing watchlists.

  Provides CRUD operations for watchlists and real-time updates
  when new notifications arrive.
  """
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Watchlists.{Watchlist, Notifier}
  alias Abyssalwatch.Market.ModuleType

  @impl true
  def mount(_params, _session, socket) do
    # current_user is set by LiveAuth on_mount hook
    user = socket.assigns.current_user
    user_id = user && user.id

    if connected?(socket) && user_id do
      Notifier.subscribe(user_id)
    end

    watchlists = load_watchlists(user_id)
    module_types = load_module_types()

    {:ok,
     socket
     |> assign(:user_id, user_id)
     |> assign(:watchlists, watchlists)
     |> assign(:module_types, module_types)
     |> assign(:show_form, false)
     |> assign(:editing_watchlist, nil)
     |> assign(:form, nil)
     |> assign(:form_data, default_form_data())
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_params(%{"action" => "new"}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_watchlist, nil)
     |> assign(:form_data, default_form_data())}
  end

  @impl true
  def handle_params(%{"action" => "edit", "id" => id}, _uri, socket) do
    case find_watchlist(socket.assigns.watchlists, id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Watchlist not found")
         |> push_navigate(to: ~p"/watchlists")}

      watchlist ->
        {:noreply,
         socket
         |> assign(:show_form, true)
         |> assign(:editing_watchlist, watchlist)
         |> assign(:form_data, watchlist_to_form_data(watchlist))}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, show_form: false, editing_watchlist: nil)}
  end

  # Form events

  @impl true
  def handle_event("show_form", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/watchlists?action=new")}
  end

  @impl true
  def handle_event("cancel_form", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/watchlists")}
  end

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

  # Watchlist actions

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case find_watchlist(socket.assigns.watchlists, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Watchlist not found")}

      watchlist ->
        case Ash.destroy(watchlist) do
          :ok ->
            watchlists = Enum.reject(socket.assigns.watchlists, &(&1.id == id))

            {:noreply,
             socket
             |> assign(:watchlists, watchlists)
             |> put_flash(:info, "Watchlist deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete watchlist")}
        end
    end
  end

  @impl true
  def handle_event("toggle_notifications", %{"id" => id}, socket) do
    case find_watchlist(socket.assigns.watchlists, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Watchlist not found")}

      watchlist ->
        case Ash.update(watchlist, %{}, action: :toggle_notifications) do
          {:ok, updated} ->
            watchlists = update_watchlist_in_list(socket.assigns.watchlists, updated)
            {:noreply, assign(socket, :watchlists, watchlists)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle notifications")}
        end
    end
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/watchlists?action=edit&id=#{id}")}
  end

  # Attribute management in form

  @impl true
  def handle_event("add_important_attr", _params, socket) do
    form_data = socket.assigns.form_data
    important_attrs = form_data.important_attributes ++ [%{name: "", value: ""}]

    {:noreply, assign(socket, :form_data, %{form_data | important_attributes: important_attrs})}
  end

  @impl true
  def handle_event("remove_important_attr", %{"index" => index}, socket) do
    {idx, _} = Integer.parse(index)
    form_data = socket.assigns.form_data
    important_attrs = List.delete_at(form_data.important_attributes, idx)

    {:noreply, assign(socket, :form_data, %{form_data | important_attributes: important_attrs})}
  end

  @impl true
  def handle_event("add_unimportant_attr", _params, socket) do
    form_data = socket.assigns.form_data
    unimportant_attrs = form_data.unimportant_attributes ++ [%{name: "", value: ""}]

    {:noreply,
     assign(socket, :form_data, %{form_data | unimportant_attributes: unimportant_attrs})}
  end

  @impl true
  def handle_event("remove_unimportant_attr", %{"index" => index}, socket) do
    {idx, _} = Integer.parse(index)
    form_data = socket.assigns.form_data
    unimportant_attrs = List.delete_at(form_data.unimportant_attributes, idx)

    {:noreply,
     assign(socket, :form_data, %{form_data | unimportant_attributes: unimportant_attrs})}
  end

  # PubSub handlers

  @impl true
  def handle_info({:new_notification, payload}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "New match for #{payload.watchlist_name}: #{payload.module_name}")}
  end

  @impl true
  def handle_info({:watchlist_update, _payload}, socket) do
    # Reload watchlists when there's an update
    watchlists = load_watchlists(socket.assigns.user_id)
    {:noreply, assign(socket, :watchlists, watchlists)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # Private helpers

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

  defp find_watchlist(watchlists, id) do
    Enum.find(watchlists, &(&1.id == id))
  end

  defp update_watchlist_in_list(watchlists, updated) do
    Enum.map(watchlists, fn w ->
      if w.id == updated.id, do: updated, else: w
    end)
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
      min_score: parse_float(params["min_score"]),
      notifications_enabled: params["notifications_enabled"] == "true"
    }
  end

  defp find_module_type_by_id(nil), do: nil
  defp find_module_type_by_id(""), do: nil

  defp find_module_type_by_id(id) do
    case Integer.parse(id) do
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

  defp parse_float(nil), do: nil
  defp parse_float(""), do: nil

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp validate_form(form_data) do
    errors = %{}

    errors =
      if String.trim(form_data.name) == "" do
        Map.put(errors, :name, "Name is required")
      else
        errors
      end

    errors =
      if is_nil(form_data.module_type_id) do
        Map.put(errors, :module_type_id, "Module type is required")
      else
        errors
      end

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
         |> put_flash(:info, "Watchlist created")
         |> push_patch(to: ~p"/watchlists")}

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
         |> put_flash(:info, "Watchlist updated")
         |> push_patch(to: ~p"/watchlists")}

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
      {name, parse_float(value) || value}
    end)
  end

  defp attrs_list_to_map(_), do: %{}

  # Template rendering
  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="flex justify-between items-center mb-8">
        <h1 class="text-3xl font-bold">Watchlists</h1>
        <button
          :if={!@show_form}
          class="btn btn-primary"
          phx-click="show_form"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-5 w-5 mr-2"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          New Watchlist
        </button>
      </div>

      <%= if @show_form do %>
        <.watchlist_form
          form_data={@form_data}
          form_errors={@form_errors}
          module_types={@module_types}
          editing={@editing_watchlist != nil}
        />
      <% else %>
        <.watchlist_list watchlists={@watchlists} />
      <% end %>
    </div>
    """
  end

  # Component for the watchlist form
  defp watchlist_form(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title">
          {if @editing, do: "Edit Watchlist", else: "New Watchlist"}
        </h2>

        <form phx-submit="save" phx-change="validate" class="space-y-4">
          <input type="hidden" name="watchlist[notifications_enabled]" value="false" />

          <div class="form-control">
            <label class="label">
              <span class="label-text">Name *</span>
            </label>
            <input
              type="text"
              name="watchlist[name]"
              class={"input input-bordered #{if @form_errors[:name], do: "input-error"}"}
              value={@form_data.name}
              placeholder="My Watchlist"
            />
            <label :if={@form_errors[:name]} class="label">
              <span class="label-text-alt text-error">{@form_errors[:name]}</span>
            </label>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Module Type *</span>
            </label>
            <select
              name="watchlist[module_type_id]"
              class={"select select-bordered #{if @form_errors[:module_type_id], do: "select-error"}"}
              disabled={@editing}
            >
              <option value="">Select a module type...</option>
              <%= for type <- @module_types do %>
                <option
                  value={type.eve_type_id}
                  selected={@form_data.module_type_id == type.eve_type_id}
                >
                  {type.name} ({type.category})
                </option>
              <% end %>
            </select>
            <label :if={@form_errors[:module_type_id]} class="label">
              <span class="label-text-alt text-error">{@form_errors[:module_type_id]}</span>
            </label>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text">Max Price (ISK)</span>
              </label>
              <input
                type="number"
                name="watchlist[price_threshold]"
                class="input input-bordered"
                value={@form_data.price_threshold}
                placeholder="No limit"
              />
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Min Score (0-1)</span>
              </label>
              <input
                type="number"
                name="watchlist[min_score]"
                class="input input-bordered"
                value={@form_data.min_score}
                step="0.1"
                min="0"
                max="1"
                placeholder="No limit"
              />
            </div>
          </div>
          
    <!-- Important Attributes -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold">Important Attributes (Minimum Values)</span>
            </label>
            <div class="space-y-2">
              <%= for {attr, idx} <- Enum.with_index(@form_data.important_attributes) do %>
                <div class="flex gap-2">
                  <input
                    type="text"
                    name={"watchlist[important_attributes][#{idx}][name]"}
                    class="input input-bordered input-sm flex-1"
                    value={attr.name || attr[:name]}
                    placeholder="Attribute name"
                  />
                  <input
                    type="text"
                    name={"watchlist[important_attributes][#{idx}][value]"}
                    class="input input-bordered input-sm w-32"
                    value={attr.value || attr[:value]}
                    placeholder="Min value"
                  />
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost btn-circle"
                    phx-click="remove_important_attr"
                    phx-value-index={idx}
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
                        d="M6 18L18 6M6 6l12 12"
                      />
                    </svg>
                  </button>
                </div>
              <% end %>
              <button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="add_important_attr"
              >
                + Add Important Attribute
              </button>
            </div>
          </div>
          
    <!-- Unimportant Attributes -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold">Unimportant Attributes (Maximum Values)</span>
            </label>
            <div class="space-y-2">
              <%= for {attr, idx} <- Enum.with_index(@form_data.unimportant_attributes) do %>
                <div class="flex gap-2">
                  <input
                    type="text"
                    name={"watchlist[unimportant_attributes][#{idx}][name]"}
                    class="input input-bordered input-sm flex-1"
                    value={attr.name || attr[:name]}
                    placeholder="Attribute name"
                  />
                  <input
                    type="text"
                    name={"watchlist[unimportant_attributes][#{idx}][value]"}
                    class="input input-bordered input-sm w-32"
                    value={attr.value || attr[:value]}
                    placeholder="Max value"
                  />
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost btn-circle"
                    phx-click="remove_unimportant_attr"
                    phx-value-index={idx}
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
                        d="M6 18L18 6M6 6l12 12"
                      />
                    </svg>
                  </button>
                </div>
              <% end %>
              <button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="add_unimportant_attr"
              >
                + Add Unimportant Attribute
              </button>
            </div>
          </div>

          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="watchlist[notifications_enabled]"
                class="checkbox"
                checked={@form_data.notifications_enabled}
                value="true"
              />
              <span class="label-text">Enable notifications</span>
            </label>
          </div>

          <div class="card-actions justify-end">
            <button type="button" class="btn btn-ghost" phx-click="cancel_form">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              {if @editing, do: "Update", else: "Create"}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # Component for the watchlist list
  defp watchlist_list(assigns) do
    ~H"""
    <div>
      <%= if Enum.empty?(@watchlists) do %>
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
          <h3 class="mt-2 text-sm font-medium">No watchlists</h3>
          <p class="mt-1 text-sm text-gray-500">
            Create a watchlist to monitor abyssal modules.
          </p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <%= for watchlist <- @watchlists do %>
            <div class="card bg-base-200">
              <div class="card-body">
                <div class="flex justify-between items-start">
                  <h2 class="card-title">{watchlist.name}</h2>
                  <div class="badge badge-outline">
                    {if watchlist.notifications_enabled, do: "Active", else: "Paused"}
                  </div>
                </div>

                <p class="text-sm text-gray-500">{watchlist.module_type_name}</p>

                <div class="mt-2 space-y-1 text-sm">
                  <%= if watchlist.price_threshold do %>
                    <div>
                      <span class="text-gray-500">Max Price:</span>
                      <span class="font-medium">{format_price(watchlist.price_threshold)}</span>
                    </div>
                  <% end %>
                  <%= if watchlist.min_score do %>
                    <div>
                      <span class="text-gray-500">Min Score:</span>
                      <span class="font-medium">{Float.round(watchlist.min_score, 2)}</span>
                    </div>
                  <% end %>
                  <%= if map_size(watchlist.important_attributes || %{}) > 0 do %>
                    <div>
                      <span class="text-gray-500">Important attrs:</span>
                      <span class="font-medium">{map_size(watchlist.important_attributes)}</span>
                    </div>
                  <% end %>
                </div>

                <div class="mt-2">
                  <span class="text-xs text-gray-500">
                    {watchlist.match_count} matches
                    <%= if watchlist.last_checked_at do %>
                      · Last checked {format_time_ago(watchlist.last_checked_at)}
                    <% end %>
                  </span>
                </div>

                <div class="card-actions justify-end mt-4">
                  <button
                    class="btn btn-sm btn-ghost"
                    phx-click="toggle_notifications"
                    phx-value-id={watchlist.id}
                  >
                    {if watchlist.notifications_enabled, do: "Pause", else: "Resume"}
                  </button>
                  <button
                    class="btn btn-sm btn-ghost"
                    phx-click="edit"
                    phx-value-id={watchlist.id}
                  >
                    Edit
                  </button>
                  <button
                    class="btn btn-sm btn-ghost text-error"
                    phx-click="delete"
                    phx-value-id={watchlist.id}
                    data-confirm="Are you sure you want to delete this watchlist?"
                  >
                    Delete
                  </button>
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
end
