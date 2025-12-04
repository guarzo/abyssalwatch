defmodule AbyssalwatchWeb.SearchLive do
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Market.ModuleType
  alias Abyssalwatch.Market.Scoring.{Topsis, Criteria}
  alias Abyssalwatch.Market.Mutamarket.Client, as: MutamarketClient
  alias Abyssalwatch.Preferences.Store, as: Preferences

  @impl true
  def mount(_params, session, socket) do
    module_types = load_module_types()
    session_id = session["session_id"]
    recent_searches = Preferences.get_recent_searches(session_id)

    {:ok,
     socket
     |> assign(:session_id, session_id)
     |> assign(:module_types, module_types)
     |> assign(:selected_type, nil)
     |> assign(:modules, [])
     |> assign(:raw_modules, [])
     |> assign(:loading, false)
     |> assign(:error, nil)
     |> assign(:criteria, Criteria.default())
     |> assign(:criteria_preset, "default")
     |> assign(:filters, default_filters())
     |> assign(:attribute_filters, %{})
     |> assign(:available_attributes, [])
     |> assign(:sort_by, "score")
     |> assign(:sort_order, "desc")
     |> assign(:recent_searches, recent_searches)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    type_id = params["type_id"]
    preset = params["preset"] || socket.assigns.criteria_preset

    # Parse type_id
    socket =
      if type_id do
        case Integer.parse(type_id) do
          {id, _} ->
            selected = Enum.find(socket.assigns.module_types, &(&1.eve_type_id == id))
            assign(socket, :selected_type, selected)

          :error ->
            socket
        end
      else
        socket
      end

    # Apply preset from URL params (persists preference across page loads)
    socket =
      if preset && preset != socket.assigns.criteria_preset do
        criteria = Criteria.preset(preset)

        # Re-score with new criteria if modules exist
        modules =
          if Enum.any?(socket.assigns.raw_modules) do
            score_and_filter(
              socket.assigns.raw_modules,
              criteria,
              socket.assigns.filters,
              socket.assigns.attribute_filters
            )
          else
            []
          end

        socket
        |> assign(:criteria, criteria)
        |> assign(:criteria_preset, preset)
        |> assign(:modules, modules)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_type", %{"type_id" => type_id}, socket) do
    case Integer.parse(type_id) do
      {id, _} ->
        selected = Enum.find(socket.assigns.module_types, &(&1.eve_type_id == id))

        # Extract available attributes from the module type's base_attributes
        available_attrs = extract_available_attributes(selected)

        socket =
          socket
          |> assign(:selected_type, selected)
          |> assign(:modules, [])
          |> assign(:raw_modules, [])
          |> assign(:error, nil)
          |> assign(:available_attributes, available_attrs)
          |> assign(:attribute_filters, %{})

        {:noreply, push_patch(socket, to: build_search_url(id, socket.assigns.criteria_preset))}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search", _params, socket) do
    case socket.assigns.selected_type do
      nil ->
        {:noreply, put_flash(socket, :error, "Please select a module type")}

      type ->
        socket = assign(socket, :loading, true)
        send(self(), {:perform_search, type.eve_type_id})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_criteria", %{"preset" => preset}, socket) do
    criteria = Criteria.preset(preset)

    # Re-score with new criteria
    modules =
      if Enum.any?(socket.assigns.raw_modules) do
        score_and_filter(
          socket.assigns.raw_modules,
          criteria,
          socket.assigns.filters,
          socket.assigns.attribute_filters
        )
      else
        []
      end

    type_id =
      if socket.assigns.selected_type do
        socket.assigns.selected_type.eve_type_id
      else
        nil
      end

    socket =
      socket
      |> assign(:criteria, criteria)
      |> assign(:criteria_preset, preset)
      |> assign(:modules, modules)

    # Update URL to persist preset preference
    {:noreply, push_patch(socket, to: build_search_url(type_id, preset), replace: true)}
  end

  @impl true
  def handle_event("update_filters", params, socket) do
    filters = %{
      min_price: parse_decimal(params["min_price"]),
      max_price: parse_decimal(params["max_price"]),
      min_score: parse_float(params["min_score"])
    }

    modules =
      score_and_filter(
        socket.assigns.raw_modules,
        socket.assigns.criteria,
        filters,
        socket.assigns.attribute_filters
      )

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:modules, modules)}
  end

  @impl true
  def handle_event("update_attribute_filter", params, socket) do
    attr_name = params["attribute"]
    min_val = parse_float(params["min"])
    max_val = parse_float(params["max"])

    # Update attribute filters map
    attribute_filters =
      socket.assigns.attribute_filters
      |> Map.put(attr_name, %{min: min_val, max: max_val})
      |> Enum.reject(fn {_k, v} -> is_nil(v.min) and is_nil(v.max) end)
      |> Map.new()

    modules =
      score_and_filter(
        socket.assigns.raw_modules,
        socket.assigns.criteria,
        socket.assigns.filters,
        attribute_filters
      )

    {:noreply,
     socket
     |> assign(:attribute_filters, attribute_filters)
     |> assign(:modules, modules)}
  end

  @impl true
  def handle_event("sort", %{"by" => sort_by}, socket) do
    {sort_by, sort_order} =
      if socket.assigns.sort_by == sort_by do
        # Toggle order if same column
        new_order = if socket.assigns.sort_order == "asc", do: "desc", else: "asc"
        {sort_by, new_order}
      else
        {sort_by, "desc"}
      end

    modules = sort_modules(socket.assigns.modules, sort_by, sort_order)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign(:sort_order, sort_order)
     |> assign(:modules, modules)}
  end

  @impl true
  def handle_info({:perform_search, type_id}, socket) do
    case MutamarketClient.search_modules(type_id) do
      {:ok, raw_modules} ->
        # Merge criteria with module type directions
        criteria =
          if socket.assigns.selected_type do
            Criteria.merge_with_module_type(
              socket.assigns.criteria,
              socket.assigns.selected_type
            )
          else
            socket.assigns.criteria
          end

        # Extract available attributes from actual module data if type doesn't have them
        available_attrs =
          if Enum.empty?(socket.assigns.available_attributes) and Enum.any?(raw_modules) do
            extract_attributes_from_modules(raw_modules)
          else
            socket.assigns.available_attributes
          end

        modules =
          score_and_filter(
            raw_modules,
            criteria,
            socket.assigns.filters,
            socket.assigns.attribute_filters
          )

        # Store the search in recent searches
        if socket.assigns.session_id && socket.assigns.selected_type do
          Preferences.add_recent_search(socket.assigns.session_id, %{
            type_id: type_id,
            type_name: socket.assigns.selected_type.name,
            preset: socket.assigns.criteria_preset,
            result_count: length(modules)
          })
        end

        # Update recent searches in assigns
        recent_searches = Preferences.get_recent_searches(socket.assigns.session_id)

        {:noreply,
         socket
         |> assign(:raw_modules, raw_modules)
         |> assign(:modules, modules)
         |> assign(:criteria, criteria)
         |> assign(:loading, false)
         |> assign(:error, nil)
         |> assign(:available_attributes, available_attrs)
         |> assign(:recent_searches, recent_searches)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error, format_error(reason))}
    end
  end

  # Private helpers

  defp load_module_types do
    case Ash.read(ModuleType) do
      {:ok, types} -> Enum.sort_by(types, & &1.name)
      {:error, _} -> []
    end
  end

  defp extract_available_attributes(nil), do: []

  defp extract_available_attributes(module_type) do
    base_attrs = module_type.base_attributes || %{}

    base_attrs
    |> Enum.map(fn {name, meta} ->
      %{
        name: name,
        display_name: get_in(meta, ["display_name"]) || humanize_attr_name(name),
        direction: get_in(meta, ["direction"]) || "higher_better"
      }
    end)
    |> Enum.sort_by(& &1.display_name)
  end

  defp extract_attributes_from_modules(modules) do
    # Collect all unique attribute names from actual module data
    modules
    |> Enum.flat_map(fn m ->
      attrs = m[:attributes] || m.attributes || %{}
      Map.keys(attrs)
    end)
    |> Enum.uniq()
    |> Enum.map(fn name ->
      %{
        name: to_string(name),
        display_name: humanize_attr_name(to_string(name)),
        direction: "higher_better"
      }
    end)
    |> Enum.sort_by(& &1.display_name)
  end

  defp humanize_attr_name(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize_attr_name(name), do: to_string(name)

  defp default_filters do
    %{
      min_price: nil,
      max_price: nil,
      min_score: nil
    }
  end

  defp score_and_filter(raw_modules, criteria, filters, attribute_filters) do
    raw_modules
    |> Topsis.score(criteria)
    |> apply_filters(filters)
    |> apply_attribute_filters(attribute_filters)
    |> sort_modules("score", "desc")
  end

  defp apply_filters(modules, filters) do
    modules
    |> maybe_filter_min_price(filters.min_price)
    |> maybe_filter_max_price(filters.max_price)
    |> maybe_filter_min_score(filters.min_score)
  end

  defp apply_attribute_filters(modules, attribute_filters)
       when map_size(attribute_filters) == 0 do
    modules
  end

  defp apply_attribute_filters(modules, attribute_filters) do
    Enum.filter(modules, fn %{module: m} ->
      attrs = m[:attributes] || m.attributes || %{}

      Enum.all?(attribute_filters, fn {attr_name, %{min: min_val, max: max_val}} ->
        case get_attribute_value(attrs, attr_name) do
          # If attribute not present, don't filter out
          nil ->
            true

          value ->
            meets_min = is_nil(min_val) or value >= min_val
            meets_max = is_nil(max_val) or value <= max_val
            meets_min and meets_max
        end
      end)
    end)
  end

  defp get_attribute_value(attrs, attr_name) do
    # Try multiple key formats (string, atom, etc.)
    value = attrs[attr_name] || attrs[String.to_atom(attr_name)] || attrs[to_string(attr_name)]

    case value do
      nil ->
        nil

      v when is_number(v) ->
        v

      v when is_binary(v) ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_filter_min_price(modules, nil), do: modules

  defp maybe_filter_min_price(modules, min_price) do
    Enum.filter(modules, fn %{module: m} ->
      price = m[:price] || m.price || Decimal.new(0)
      Decimal.compare(price, min_price) != :lt
    end)
  end

  defp maybe_filter_max_price(modules, nil), do: modules

  defp maybe_filter_max_price(modules, max_price) do
    Enum.filter(modules, fn %{module: m} ->
      price = m[:price] || m.price || Decimal.new(0)
      Decimal.compare(price, max_price) != :gt
    end)
  end

  defp maybe_filter_min_score(modules, nil), do: modules

  defp maybe_filter_min_score(modules, min_score) do
    Enum.filter(modules, fn %{score: score} -> score >= min_score end)
  end

  defp sort_modules(modules, sort_by, order) do
    sorted =
      Enum.sort_by(modules, fn %{module: m, score: score} ->
        case sort_by do
          "score" -> score
          "price" -> Decimal.to_float(m[:price] || m.price || Decimal.new(0))
          "name" -> m[:name] || m.name || ""
          _ -> score
        end
      end)

    if order == "asc", do: sorted, else: Enum.reverse(sorted)
  end

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

  defp format_error(:not_found), do: "No modules found for this type"
  defp format_error(:rate_limited), do: "API rate limit exceeded. Please try again later."
  defp format_error({:http_error, status}), do: "HTTP error: #{status}"
  defp format_error({:transport_error, reason}), do: "Network error: #{inspect(reason)}"
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  # Build search URL with optional type_id and preset params
  defp build_search_url(nil, "default"), do: "/search"
  defp build_search_url(nil, preset), do: "/search?preset=#{preset}"
  defp build_search_url(type_id, "default"), do: "/search?type_id=#{type_id}"
  defp build_search_url(type_id, preset), do: "/search?type_id=#{type_id}&preset=#{preset}"

  # Template rendering
  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <h1 class="text-3xl font-bold mb-8">Abyssal Module Search</h1>

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
        <!-- Sidebar - Filters -->
        <div class="lg:col-span-1">
          <div class="bg-base-200 rounded-lg p-4 space-y-6">
            <!-- Module Type Selection -->
            <form phx-change="select_type">
              <label class="label">
                <span class="label-text font-semibold">Module Type</span>
              </label>
              <select
                class="select select-bordered w-full"
                name="type_id"
              >
                <option value="">Select a type...</option>
                <%= for type <- @module_types do %>
                  <option
                    value={type.eve_type_id}
                    selected={@selected_type && @selected_type.id == type.id}
                  >
                    {type.name} ({type.category})
                  </option>
                <% end %>
              </select>
            </form>
            
    <!-- Scoring Preset -->
            <form phx-change="update_criteria">
              <label class="label">
                <span class="label-text font-semibold">Scoring Profile</span>
              </label>
              <select
                class="select select-bordered w-full"
                name="preset"
              >
                <option value="default" selected={@criteria_preset == "default"}>
                  Default (Balanced)
                </option>
                <option value="conservative" selected={@criteria_preset == "conservative"}>
                  Conservative (Budget)
                </option>
                <option value="aggressive" selected={@criteria_preset == "aggressive"}>
                  Aggressive (Performance)
                </option>
              </select>
            </form>
            
    <!-- Price Filters -->
            <form phx-change="update_filters" class="space-y-4">
              <div>
                <label class="label">
                  <span class="label-text">Min Price (ISK)</span>
                </label>
                <input
                  type="number"
                  name="min_price"
                  class="input input-bordered w-full"
                  placeholder="0"
                  value={@filters.min_price}
                />
              </div>
              <div>
                <label class="label">
                  <span class="label-text">Max Price (ISK)</span>
                </label>
                <input
                  type="number"
                  name="max_price"
                  class="input input-bordered w-full"
                  placeholder="No limit"
                  value={@filters.max_price}
                />
              </div>
              <div>
                <label class="label">
                  <span class="label-text">Min Score (0-1)</span>
                </label>
                <input
                  type="number"
                  name="min_score"
                  class="input input-bordered w-full"
                  placeholder="0"
                  step="0.1"
                  min="0"
                  max="1"
                  value={@filters.min_score}
                />
              </div>
            </form>
            
    <!-- Attribute Filters -->
            <%= if Enum.any?(@available_attributes) do %>
              <div class="divider text-xs">Attribute Filters</div>
              <div class="space-y-3 max-h-64 overflow-y-auto">
                <%= for attr <- @available_attributes do %>
                  <div class="bg-base-100 rounded p-2">
                    <label class="label py-0">
                      <span class="label-text text-xs font-medium">{attr.display_name}</span>
                      <span class="label-text-alt text-xs text-gray-400">
                        {if attr.direction == "higher_better",
                          do: "higher better",
                          else: "lower better"}
                      </span>
                    </label>
                    <form phx-change="update_attribute_filter" class="flex gap-2">
                      <input type="hidden" name="attribute" value={attr.name} />
                      <input
                        type="number"
                        step="any"
                        class="input input-bordered input-sm w-full"
                        placeholder="Min"
                        name="min"
                        value={get_in(@attribute_filters, [attr.name, :min])}
                        phx-debounce="500"
                      />
                      <input
                        type="number"
                        step="any"
                        class="input input-bordered input-sm w-full"
                        placeholder="Max"
                        name="max"
                        value={get_in(@attribute_filters, [attr.name, :max])}
                        phx-debounce="500"
                      />
                    </form>
                  </div>
                <% end %>
              </div>
            <% end %>
            
    <!-- Search Button -->
            <button
              class="btn btn-primary w-full"
              phx-click="search"
              disabled={@loading || is_nil(@selected_type)}
            >
              <%= if @loading do %>
                <span class="loading loading-spinner loading-sm"></span> Searching...
              <% else %>
                Search Modules
              <% end %>
            </button>
          </div>
        </div>
        
    <!-- Main Content - Results -->
        <div class="lg:col-span-3">
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

          <%= if Enum.empty?(@modules) && !@loading do %>
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
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
              <h3 class="mt-2 text-sm font-medium">No modules found</h3>
              <p class="mt-1 text-sm text-gray-500">
                Select a module type and click Search to find abyssal modules.
              </p>
            </div>
          <% else %>
            <!-- Results Header -->
            <div class="flex justify-between items-center mb-4">
              <p class="text-sm text-gray-500">
                Found <span class="font-semibold">{length(@modules)}</span>
                modules
                <%= if length(@raw_modules) != length(@modules) do %>
                  (filtered from {length(@raw_modules)})
                <% end %>
              </p>
            </div>
            
    <!-- Results Table -->
            <div class="overflow-x-auto">
              <table class="table table-zebra w-full">
                <thead>
                  <tr>
                    <th>
                      <button phx-click="sort" phx-value-by="name" class="flex items-center gap-1">
                        Name {sort_indicator("name", @sort_by, @sort_order)}
                      </button>
                    </th>
                    <th>
                      <button phx-click="sort" phx-value-by="score" class="flex items-center gap-1">
                        Score {sort_indicator("score", @sort_by, @sort_order)}
                      </button>
                    </th>
                    <th>
                      <button phx-click="sort" phx-value-by="price" class="flex items-center gap-1">
                        Price {sort_indicator("price", @sort_by, @sort_order)}
                      </button>
                    </th>
                    <th>Attributes</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for {%{module: module, score: score, breakdown: _breakdown}, idx} <- Enum.with_index(@modules) do %>
                    <tr class={if rem(idx, 2) == 0, do: "bg-base-200", else: ""}>
                      <td>
                        <div class="font-medium">{module[:name] || module.name}</div>
                        <div class="text-xs text-gray-500">
                          {module[:type_name] || module.type_name}
                        </div>
                      </td>
                      <td>
                        <div class="flex items-center gap-2">
                          <div
                            class={"radial-progress text-xs #{score_color(score)}"}
                            style={"--value:#{round(score * 100)}; --size:2rem;"}
                          >
                            {round(score * 100)}
                          </div>
                        </div>
                      </td>
                      <td>
                        <span class="font-mono">
                          {format_price(module[:price] || module.price)}
                        </span>
                      </td>
                      <td>
                        <div class="text-xs space-y-1">
                          <%= for {attr, value} <- Enum.take(module[:attributes] || module.attributes || %{}, 3) do %>
                            <div>
                              <span class="text-gray-500">{attr}:</span>
                              <span class="font-medium">{format_attribute_value(value)}</span>
                            </div>
                          <% end %>
                          <%= if map_size(module[:attributes] || module.attributes || %{}) > 3 do %>
                            <div class="text-gray-400">
                              +{map_size(module[:attributes] || module.attributes || %{}) - 3} more
                            </div>
                          <% end %>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp sort_indicator(column, current_sort, order) do
    if column == current_sort do
      if order == "asc" do
        Phoenix.HTML.raw(
          ~s(<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 15l7-7 7 7"></path></svg>)
        )
      else
        Phoenix.HTML.raw(
          ~s(<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"></path></svg>)
        )
      end
    else
      Phoenix.HTML.raw(
        ~s(<svg class="w-4 h-4 opacity-30" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4"></path></svg>)
      )
    end
  end

  defp score_color(score) when score >= 0.8, do: "text-success"
  defp score_color(score) when score >= 0.6, do: "text-info"
  defp score_color(score) when score >= 0.4, do: "text-warning"
  defp score_color(_), do: "text-error"

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

  defp format_attribute_value(value) when is_float(value) do
    Float.round(value, 2) |> to_string()
  end

  defp format_attribute_value(value), do: to_string(value)
end
