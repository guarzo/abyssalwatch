defmodule AbyssalwatchWeb.SearchLive do
  use AbyssalwatchWeb, :live_view

  require Logger

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
     |> assign(:active, :search)
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
     |> assign(:recent_searches, recent_searches)
     |> assign(:selected_module, nil)
     |> assign(:fetched_at, nil)
     |> assign(:copy_state, :idle)}
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
  def handle_event("select_row", %{"id" => id}, socket) do
    selected =
      Enum.find(socket.assigns.modules, fn entry ->
        module_dom_id(entry) == id
      end)

    cond do
      is_nil(selected) ->
        {:noreply, socket}

      socket.assigns.selected_module && module_dom_id(socket.assigns.selected_module) == id ->
        # Toggle off
        {:noreply, assign(socket, selected_module: nil, copy_state: :idle)}

      true ->
        {:noreply, assign(socket, selected_module: selected, copy_state: :idle)}
    end
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, selected_module: nil, copy_state: :idle)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = default_filters()
    attribute_filters = %{}

    modules =
      score_and_filter(
        socket.assigns.raw_modules,
        socket.assigns.criteria,
        filters,
        attribute_filters
      )

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:attribute_filters, attribute_filters)
     |> assign(:modules, modules)}
  end

  @impl true
  def handle_event("copy_contract", _params, socket) do
    Process.send_after(self(), :clear_copy_state, 1200)
    {:noreply, assign(socket, :copy_state, :copied)}
  end

  @impl true
  def handle_event("load_recent", %{"type_id" => type_id}, socket) do
    case Integer.parse(type_id) do
      {id, _} ->
        selected = Enum.find(socket.assigns.module_types, &(&1.eve_type_id == id))
        available_attrs = extract_available_attributes(selected)

        socket =
          socket
          |> assign(:selected_type, selected)
          |> assign(:modules, [])
          |> assign(:raw_modules, [])
          |> assign(:error, nil)
          |> assign(:available_attributes, available_attrs)
          |> assign(:attribute_filters, %{})
          |> assign(:loading, true)

        send(self(), {:perform_search, id})
        {:noreply, push_patch(socket, to: build_search_url(id, socket.assigns.criteria_preset))}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:clear_copy_state, socket) do
    {:noreply, assign(socket, :copy_state, :idle)}
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
         |> assign(:recent_searches, recent_searches)
         |> assign(:fetched_at, DateTime.utc_now())
         |> assign(:selected_module, nil)}

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
      {:ok, []} ->
        Logger.warning(
          "SearchLive.load_module_types: ModuleType table is empty — run Abyssalwatch.Release.seed/0"
        )

        []

      {:ok, types} ->
        Enum.sort_by(types, & &1.name)

      {:error, error} ->
        Logger.error("SearchLive.load_module_types failed: #{inspect(error)}")
        []
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
    # Try multiple key formats (string, atom, etc.). Avoid String.to_atom/1 on
    # user-supplied attr_name to prevent atom exhaustion.
    value =
      attrs[attr_name] ||
        attrs[to_string(attr_name)] ||
        attrs[safe_existing_atom(attr_name)]

    case value do
      nil ->
        nil

      # New structure with value/base_value map
      %{"value" => v} when is_number(v) ->
        v

      %{"value" => v} when is_binary(v) ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> nil
        end

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
          "score" ->
            score

          "price" ->
            Decimal.to_float(m[:price] || m.price || Decimal.new(0))

          "name" ->
            m[:name] || m.name || ""

          "base_module" ->
            m[:source_type_name] || ""

          # Sort by attribute value
          attr_name ->
            attrs = m[:attributes] || m.attributes || %{}

            case Map.get(attrs, attr_name) do
              %{"value" => value} when is_number(value) -> value
              value when is_number(value) -> value
              _ -> 0.0
            end
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

  # Get ordered list of attribute names for the current result set
  defp get_display_attributes(modules) do
    if Enum.empty?(modules) do
      []
    else
      # Get all unique attribute names from results
      modules
      |> Enum.flat_map(fn %{module: m} ->
        attrs = m[:attributes] || m.attributes || %{}
        Map.keys(attrs)
      end)
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  # Stable per-row DOM id used by phx-click/value-id. Mutamarket may
  # return multiple rolls per contract and modules without a unique :id;
  # we tail every id with a phash of the *module map* (not the full
  # entry) so the id is stable across rescoring — entry includes the
  # transient :score which would otherwise change with every criteria
  # tweak and break LiveView's phx-update tracking.
  defp module_dom_id(%{module: m}) do
    base =
      first_present([
        m[:id],
        m[:contract_id],
        m[:contract_url]
      ]) || "x"

    "row-#{base}-#{:erlang.phash2(m)}"
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
  end

  defp first_present([]), do: nil
  defp first_present([nil | rest]), do: first_present(rest)
  defp first_present(["" | rest]), do: first_present(rest)
  defp first_present([v | _]), do: v

  defp filter_chip_summary(filters, attribute_filters) do
    price = if filters.min_price || filters.max_price, do: 1, else: 0
    score = if filters.min_score, do: 1, else: 0
    price + score + map_size(attribute_filters)
  end

  # Mutamarket contract URL when the upstream provides one.
  defp contract_url(%{module: m}) do
    m[:mutamarket_url] || m[:url] || m["url"] || nil
  end

  # Display-friendly attribute name from snake_case.
  defp humanize(attr) when is_binary(attr) do
    attr
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize(attr), do: humanize(to_string(attr))

  # Resolve the value/base_value/min/max for an attribute from the selected
  # module type's base_attributes map. Returns a map with the four values or
  # nil when unavailable.
  defp attribute_meta(nil, _attr_name), do: nil

  defp attribute_meta(module_type, attr_name) do
    base = module_type.base_attributes || %{}
    key = to_string(attr_name)

    case base[key] || base[safe_existing_atom(key)] do
      %{} = meta ->
        %{
          min: numeric(meta["min"] || meta[:min]),
          max: numeric(meta["max"] || meta[:max]),
          base: numeric(meta["base"] || meta[:base] || meta["base_value"] || meta[:base_value]),
          direction: meta["direction"] || meta[:direction] || "higher_better"
        }

      _ ->
        nil
    end
  end

  defp numeric(nil), do: nil
  defp numeric(n) when is_number(n), do: n * 1.0

  defp numeric(b) when is_binary(b) do
    case Float.parse(b) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp numeric(_), do: nil

  # Single unambiguous top score (returns the entry, or nil on tie / empty).
  defp top_entry([]), do: nil
  defp top_entry([only]), do: only

  defp top_entry([%{score: s1}, %{score: s2} | _] = list) do
    if s1 > s2 + 1.0e-9, do: hd(list), else: nil
  end

  # Time-ago in compact form: "4m ago", "2h ago", "3d ago".
  defp time_ago(nil), do: nil

  defp time_ago(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp stale?(%DateTime{} = dt), do: DateTime.diff(DateTime.utc_now(), dt, :second) > 300
  defp stale?(_), do: false

  defp format_score(score) when is_number(score) do
    :erlang.float_to_binary(score * 1.0, decimals: 2)
  end

  defp format_score(_), do: "—"

  # Score tier class for hero numeral and micro-bar coloring.
  # S: 0.90+ green-glow ; A: 0.80–0.89 accent-strong ; B: 0.65–0.79 ink-1 ; C: < 0.65 ink-3
  defp score_tier_class(score) when is_number(score) do
    cond do
      score >= 0.90 -> "is-s"
      score >= 0.80 -> "is-a"
      score >= 0.65 -> "is-b"
      true -> "is-c"
    end
  end

  defp score_tier_class(_), do: "is-c"

  # Text-only tier coloring for the drawer hero numeral.
  defp score_tier_text_class(score) when is_number(score) do
    cond do
      score >= 0.90 -> "text-[oklch(0.82_0.18_145)]"
      score >= 0.80 -> "text-accent-strong"
      score >= 0.65 -> "text-ink-1"
      true -> "text-ink-3"
    end
  end

  defp score_tier_text_class(_), do: "text-ink-3"

  defp watch_url(module_type, filters) do
    base = [{"new", "1"}, {"type_id", to_string(module_type.eve_type_id)}]

    optional =
      [
        {"max_price", decimal_to_param(filters[:max_price])},
        {"min_score", filters[:min_score]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)

    "/watch?" <> URI.encode_query(base ++ optional)
  end

  defp decimal_to_param(nil), do: nil
  defp decimal_to_param(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_param(other), do: other

  defp percent_position(value, %{min: mn, max: mx})
       when is_number(value) and is_number(mn) and is_number(mx) and mx > mn do
    pct = (value - mn) / (mx - mn) * 100
    pct |> max(0) |> min(100)
  end

  defp percent_position(_, _), do: nil

  defp sort_caret(column, current, order) do
    cond do
      column != current -> ""
      order == "asc" -> "▴"
      true -> "▾"
    end
  end

  defp profile_label("default"), do: "Default"
  defp profile_label("conservative"), do: "Conservative"
  defp profile_label("aggressive"), do: "Aggressive"
  defp profile_label(other), do: other |> to_string() |> String.capitalize()

  # Compact label for the segmented sidebar chip (3-col grid).
  defp profile_label_short("default"), do: "Balanced"
  defp profile_label_short("conservative"), do: "Safe"
  defp profile_label_short("aggressive"), do: "Hot"
  defp profile_label_short(other), do: profile_label(other)

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    display_attrs = get_display_attributes(assigns.modules)
    top = top_entry(assigns.modules)
    active_filters = filter_chip_summary(assigns.filters, assigns.attribute_filters)

    assigns =
      assigns
      |> assign(:display_attributes, display_attrs)
      |> assign(:top_entry, top)
      |> assign(:active_filter_count, active_filters)

    ~H"""
    <div
      class="grid gap-6 lg:grid-cols-[280px_minmax(0,1fr)] lg:gap-8"
      phx-window-keydown="close_drawer"
      phx-key="Escape"
    >
      <.filter_sidebar
        module_types={@module_types}
        selected_type={@selected_type}
        criteria_preset={@criteria_preset}
        filters={@filters}
        available_attributes={@available_attributes}
        attribute_filters={@attribute_filters}
        active_filter_count={@active_filter_count}
        loading={@loading}
        recent_searches={@recent_searches}
      />

      <div class="min-w-0">
        <.results_header
          selected_type={@selected_type}
          modules={@modules}
          raw_modules={@raw_modules}
          fetched_at={@fetched_at}
          loading={@loading}
        />

        <.error_panel :if={@error} error={@error} />

        <%= cond do %>
          <% @loading and Enum.empty?(@modules) -> %>
            <.results_skeleton />
          <% is_nil(@selected_type) and Enum.empty?(@modules) -> %>
            <.empty_initial recent_searches={@recent_searches} module_types={@module_types} />
          <% Enum.empty?(@modules) and Enum.any?(@raw_modules) -> %>
            <.empty_filtered active_filter_count={@active_filter_count} />
          <% Enum.empty?(@modules) -> %>
            <.empty_pre_search />
          <% true -> %>
            <.results_table
              modules={@modules}
              sort_by={@sort_by}
              sort_order={@sort_order}
              top_entry={@top_entry}
              selected_module={@selected_module}
              selected_type={@selected_type}
            />
        <% end %>
      </div>
    </div>

    <.detail_drawer
      :if={@selected_module}
      entry={@selected_module}
      module_type={@selected_type}
      filters={@filters}
      copy_state={@copy_state}
    />
    """
  end

  # ── Sidebar ─────────────────────────────────────────────────────────

  attr :module_types, :list, required: true
  attr :selected_type, :any, required: true
  attr :criteria_preset, :string, required: true
  attr :filters, :map, required: true
  attr :available_attributes, :list, required: true
  attr :attribute_filters, :map, required: true
  attr :active_filter_count, :integer, required: true
  attr :loading, :boolean, required: true
  attr :recent_searches, :list, required: true

  defp filter_sidebar(assigns) do
    ~H"""
    <aside class="panel self-start lg:sticky lg:top-[72px] max-h-[calc(100vh-72px)] overflow-y-auto">
      <div class="panel-header">
        <span class="sidebar-kicker">Filters</span>
        <span :if={@active_filter_count > 0} class="text-[11px] text-ink-3 tnum">
          {@active_filter_count} active
        </span>
      </div>

      <div class="panel-body space-y-5">
        <div>
          <form phx-change="select_type">
            <span class="field-label">Module type</span>
            <select class="select" name="type_id">
              <option value="">Select a type</option>
              <%= for type <- @module_types do %>
                <option
                  value={type.eve_type_id}
                  selected={@selected_type && @selected_type.id == type.id}
                >
                  {type.name}
                </option>
              <% end %>
            </select>
          </form>
        </div>

        <div>
          <span class="field-label">Scoring profile</span>
          <form phx-change="update_criteria" class="grid grid-cols-3 gap-1.5 mt-1">
            <%= for profile <- ~w(default conservative aggressive) do %>
              <label class={["profile-chip", @criteria_preset == profile && "is-active"]}>
                <input
                  type="radio"
                  name="preset"
                  value={profile}
                  checked={@criteria_preset == profile}
                  class="sr-only"
                />
                {profile_label_short(profile)}
                <div class="weight-bars" aria-hidden="true">
                  <%= for {weight, idx} <- profile_weights(profile) |> Enum.with_index() do %>
                    <div
                      class={[
                        "weight-bars-bar",
                        @criteria_preset == profile && weight >= 0.4 && "is-strong",
                        @criteria_preset == profile && weight < 0.4 && "is-active"
                      ]}
                      style={"height: #{round(weight * 100)}%"}
                    />
                  <% end %>
                </div>
              </label>
            <% end %>
          </form>
          <p class="mt-2 text-[11px] text-ink-4 leading-snug">
            {profile_hint(@criteria_preset)}
          </p>
        </div>

        <form phx-change="update_filters" class="space-y-3" phx-debounce="300">
          <span class="field-label">Price (ISK)</span>
          <div class="grid grid-cols-2 gap-2">
            <input
              type="number"
              name="min_price"
              class="input tnum"
              placeholder="Min"
              value={@filters.min_price}
            />
            <input
              type="number"
              name="max_price"
              class="input tnum"
              placeholder="Max"
              value={@filters.max_price}
            />
          </div>

          <div>
            <span class="field-label">Minimum score</span>
            <input
              type="number"
              name="min_score"
              class="input tnum"
              placeholder="0.00"
              step="0.05"
              min="0"
              max="1"
              value={@filters.min_score}
            />
          </div>
        </form>

        <%= if Enum.any?(@available_attributes) do %>
          <div>
            <span class="field-label">Attribute filters</span>
            <div class="space-y-2 mt-1 max-h-72 overflow-y-auto pr-1">
              <%= for attr <- @available_attributes do %>
                <form
                  phx-change="update_attribute_filter"
                  phx-debounce="500"
                  class="border border-rule-1 rounded-md p-2 hover:border-rule-2 transition-colors"
                >
                  <div class="flex items-center justify-between mb-1.5">
                    <span class="text-[12px] text-ink-2">{attr.display_name}</span>
                    <span class="text-[10px] text-ink-4">
                      {if attr.direction == "higher_better", do: "▲ better", else: "▼ better"}
                    </span>
                  </div>
                  <input type="hidden" name="attribute" value={attr.name} />
                  <div class="grid grid-cols-2 gap-1.5">
                    <input
                      type="number"
                      step="any"
                      class="input input-sm tnum"
                      placeholder="Min"
                      name="min"
                      value={get_in(@attribute_filters, [attr.name, :min])}
                    />
                    <input
                      type="number"
                      step="any"
                      class="input input-sm tnum"
                      placeholder="Max"
                      name="max"
                      value={get_in(@attribute_filters, [attr.name, :max])}
                    />
                  </div>
                </form>
              <% end %>
            </div>
          </div>
        <% end %>

        <div class="flex gap-2">
          <button
            type="button"
            class="btn btn-primary flex-1"
            phx-click="search"
            disabled={@loading || is_nil(@selected_type)}
          >
            <%= if @loading do %>
              <span class="animate-skeleton-pulse">Searching</span>
            <% else %>
              Search Mutamarket
            <% end %>
          </button>
          <button
            :if={@active_filter_count > 0}
            type="button"
            class="btn btn-ghost"
            phx-click="clear_filters"
            title="Clear all filters"
          >
            Clear
          </button>
        </div>
      </div>

      <%= if Enum.any?(@recent_searches) do %>
        <div class="border-t border-rule-1">
          <div class="px-4 py-3">
            <span class="field-label">Recent</span>
          </div>
          <ul class="pb-2">
            <%= for s <- Enum.take(@recent_searches, 5) do %>
              <li>
                <button
                  type="button"
                  phx-click="load_recent"
                  phx-value-type_id={s.type_id}
                  class="w-full flex items-baseline justify-between px-4 py-2 text-left hover:bg-surface-2 transition-colors"
                >
                  <span class="text-[13px] text-ink-2 truncate">{s.type_name}</span>
                  <span class="text-[11px] text-ink-4 tnum ml-3 shrink-0">
                    {time_ago(s.searched_at)}
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>
    </aside>
    """
  end

  defp profile_hint("default"), do: "Balanced weights across price, attributes, and slot fit."
  defp profile_hint("conservative"), do: "Heavier weight on price and capacitor stability."
  defp profile_hint("aggressive"), do: "Heavier weight on damage and range."
  defp profile_hint(_), do: ""

  # Illustrative weight summary for the segmented profile chips: three
  # bars representing [price, attributes, fit]. Not the exact Criteria
  # weights — directional, for visual feedback only.
  defp profile_weights("default"), do: [0.50, 0.50, 0.50]
  defp profile_weights("conservative"), do: [0.85, 0.40, 0.55]
  defp profile_weights("aggressive"), do: [0.30, 0.85, 0.45]
  defp profile_weights(_), do: [0.30, 0.30, 0.30]

  # ── Results header ───────────────────────────────────────────────────

  attr :selected_type, :any, required: true
  attr :modules, :list, required: true
  attr :raw_modules, :list, required: true
  attr :fetched_at, :any, required: true
  attr :loading, :boolean, required: true

  defp results_header(assigns) do
    ~H"""
    <%= if @selected_type do %>
      <.header>
        {@selected_type.name}
        <:subtitle>
          <%= cond do %>
            <% Enum.empty?(@raw_modules) and not @loading -> %>
              No fetch yet. Pick a type and search.
            <% true -> %>
              <span class="tnum">{length(@modules)}</span>
              <%= if length(@modules) != length(@raw_modules) do %>
                of <span class="tnum">{length(@raw_modules)}</span> results
              <% else %>
                results
              <% end %>
              <span :if={@fetched_at} class={["ml-1", stale?(@fetched_at) && "text-status-training"]}>
                · {time_ago(@fetched_at)}
              </span>
          <% end %>
        </:subtitle>
      </.header>
    <% end %>
    """
  end

  # ── States ──────────────────────────────────────────────────────────

  attr :error, :any, required: true

  defp error_panel(assigns) do
    ~H"""
    <div class="panel mb-4 border-[oklch(0.70_0.18_25/0.4)]">
      <div class="px-4 py-3 flex items-start gap-3">
        <span class="text-status-error mt-0.5" aria-hidden="true">!</span>
        <div class="flex-1 min-w-0">
          <p class="text-ink-1 text-sm">Mutamarket request failed</p>
          <p class="text-ink-3 text-[13px] mt-0.5">{@error}</p>
        </div>
        <button
          type="button"
          phx-click="search"
          class="btn btn-sm"
        >
          Retry
        </button>
      </div>
    </div>
    """
  end

  attr :recent_searches, :list, required: true
  attr :module_types, :list, default: []

  defp empty_initial(assigns) do
    quick = Enum.take(assigns.module_types, 4)
    assigns = assign(assigns, :quick_hunts, quick)

    ~H"""
    <section class="hero">
      <%!-- Decorative attribute-radar art. Behind the headline, far right.
            Five-axis polygon stack at low opacity — visual signature, not chrome. --%>
      <svg class="hero-art" viewBox="-160 -160 320 320" aria-hidden="true">
        <defs>
          <radialGradient id="hero-art-fill" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stop-color="oklch(0.72 0.13 280)" stop-opacity="0.35" />
            <stop offset="100%" stop-color="oklch(0.72 0.13 280)" stop-opacity="0" />
          </radialGradient>
        </defs>
        <%!-- Concentric pentagons (radar grid) --%>
        <%= for r <- [40, 80, 120, 150] do %>
          <polygon
            points={radar_grid_points(r)}
            fill="none"
            stroke="oklch(0.46 0.007 250)"
            stroke-width="0.5"
            opacity="0.6"
          />
        <% end %>
        <%!-- Axis lines --%>
        <%= for {x, y} <- radar_axes() do %>
          <line x1="0" y1="0" x2={x} y2={y} stroke="oklch(0.38 0.006 250)" stroke-width="0.5" />
        <% end %>
        <%!-- A representative "great roll" polygon, indigo-filled --%>
        <polygon
          points={radar_data_points([0.94, 0.78, 0.88, 0.62, 0.91])}
          fill="url(#hero-art-fill)"
          stroke="oklch(0.80 0.14 280)"
          stroke-width="1.25"
          opacity="0.85"
        />
        <%!-- Vertex dots --%>
        <%= for {x, y} <- radar_vertex_dots([0.94, 0.78, 0.88, 0.62, 0.91]) do %>
          <circle cx={x} cy={y} r="2.25" fill="oklch(0.80 0.14 280)" />
        <% end %>
        <%!-- A weaker, amber comparison polygon — represents median --%>
        <polygon
          points={radar_data_points([0.55, 0.50, 0.58, 0.45, 0.52])}
          fill="none"
          stroke="oklch(0.82 0.16 70)"
          stroke-width="0.75"
          stroke-dasharray="2 3"
          opacity="0.55"
        />
      </svg>

      <div class="hero-kicker">Mutamarket · Live</div>

      <h1 class="text-mono-display hero-headline">
        Hunt the abyss<span class="text-mono-display-tail">.</span>
      </h1>

      <p class="hero-sub">
        Score every mutaplasmid roll on the market against your fitting profile.
        Pick a module type and start fishing — the radar shows you why a number is what it is.
      </p>

      <%= if Enum.any?(@quick_hunts) do %>
        <div class="quick-hunts">
          <span class="quick-hunts-label">Quick start</span>
          <%= for t <- @quick_hunts do %>
            <button
              type="button"
              phx-click="select_type"
              phx-value-type_id={t.eve_type_id}
              class="quick-hunt"
              title={"Search " <> t.name}
            >
              <span class="quick-hunt-glyph" aria-hidden="true">▸</span>
              <span>{t.name}</span>
            </button>
          <% end %>
        </div>
      <% end %>
    </section>

    <section class="how-strip" aria-label="How AbyssalWatch works">
      <div class="how-step">
        <div class="how-step-num">01</div>
        <h3 class="how-step-title">Pick a hull profile</h3>
        <p class="how-step-body">
          Default, Conservative, or Aggressive scoring weights — or tune the criteria
          by attribute for the fit you're actually flying.
        </p>
      </div>
      <div class="how-step">
        <div class="how-step-num">02</div>
        <h3 class="how-step-title">Score the market</h3>
        <p class="how-step-body">
          We pull live Mutamarket listings and run TOPSIS against your weights.
          Every roll gets a number you can compare.
        </p>
      </div>
      <div class="how-step">
        <div class="how-step-num">03</div>
        <h3 class="how-step-title">Watch for deals</h3>
        <p class="how-step-body">
          Save a watchlist and we'll ping Discord when a roll above your threshold
          shows up below median price.
        </p>
      </div>
    </section>

    <%= if Enum.any?(@recent_searches) do %>
      <section class="panel mt-6">
        <header class="panel-header">
          <h2 class="text-meta">Recent</h2>
          <span class="text-micro">{length(@recent_searches)} hunts</span>
        </header>
        <ul>
          <%= for s <- Enum.take(@recent_searches, 5) do %>
            <li>
              <button
                type="button"
                phx-click="load_recent"
                phx-value-type_id={s.type_id}
                class="w-full flex items-center justify-between gap-4 px-4 py-2.5 text-left hover:bg-surface-2 transition-colors first:rounded-t-[10px] last:rounded-b-[10px]"
              >
                <span class="flex items-center gap-2 min-w-0">
                  <span class="text-ink-3 text-[12px]" aria-hidden="true">▸</span>
                  <span class="text-ink-1 text-sm truncate">{s.type_name}</span>
                  <span class="text-ink-4 text-[11px]">· {profile_label(s.preset)}</span>
                </span>
                <span class="text-ink-4 text-[11px] tnum shrink-0">
                  {time_ago(s.searched_at)}
                </span>
              </button>
            </li>
          <% end %>
        </ul>
      </section>
    <% end %>
    """
  end

  defp empty_pre_search(assigns) do
    ~H"""
    <div class="panel">
      <div class="px-6 py-12 text-center">
        <p class="text-ink-1 text-[15px]">Ready to search.</p>
        <p class="text-ink-3 text-[13px] mt-1">
          Press Search Mutamarket in the sidebar to fetch listings.
        </p>
      </div>
    </div>
    """
  end

  attr :active_filter_count, :integer, required: true

  defp empty_filtered(assigns) do
    ~H"""
    <div class="panel">
      <div class="px-6 py-12 text-center">
        <p class="text-ink-1 text-[15px]">No modules match these filters.</p>
        <p class="text-ink-3 text-[13px] mt-1">
          Loosen a filter, or clear all <span :if={@active_filter_count > 0} class="tnum">({@active_filter_count})</span>.
        </p>
        <button type="button" phx-click="clear_filters" class="btn btn-sm mt-4">
          Clear filters
        </button>
      </div>
    </div>
    """
  end

  defp results_skeleton(assigns) do
    ~H"""
    <div class="panel overflow-hidden">
      <table class="dense">
        <thead>
          <tr>
            <th class="w-6"></th>
            <th>Name</th>
            <th class="text-right">Score</th>
            <th class="text-right">Price</th>
            <th>Attributes</th>
          </tr>
        </thead>
        <tbody class="animate-skeleton-pulse">
          <%= for _ <- 1..5 do %>
            <tr>
              <td></td>
              <td><span class="block h-3 w-40 bg-surface-2 rounded" /></td>
              <td class="text-right">
                <span class="block h-3 w-12 bg-surface-2 rounded ml-auto" />
              </td>
              <td class="text-right">
                <span class="block h-3 w-20 bg-surface-2 rounded ml-auto" />
              </td>
              <td><span class="block h-3 w-32 bg-surface-2 rounded" /></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # ── Results table ───────────────────────────────────────────────────

  attr :modules, :list, required: true
  attr :sort_by, :string, required: true
  attr :sort_order, :string, required: true
  attr :top_entry, :any, required: true
  attr :selected_module, :any, required: true
  attr :selected_type, :any, default: nil

  defp results_table(assigns) do
    median_price = compute_median_price(assigns.modules)
    radar_attrs = pick_radar_attributes(assigns.modules)
    attr_ranges = compute_attr_ranges(assigns.modules, radar_attrs)
    attr_directions = compute_attr_directions(assigns.selected_type, radar_attrs)

    {s_tier, rest} = partition_s_tier(assigns.modules)

    assigns =
      assigns
      |> assign(:median_price, median_price)
      |> assign(:radar_attrs, radar_attrs)
      |> assign(:attr_ranges, attr_ranges)
      |> assign(:attr_directions, attr_directions)
      |> assign(:s_tier_modules, s_tier)
      |> assign(:rest_modules, rest)

    ~H"""
    <div class="panel overflow-hidden">
      <table class="dense">
        <thead>
          <tr>
            <th class={["w-6", @sort_by == "" && ""]} aria-hidden="true"></th>
            <th class={[@sort_by == "name" && "is-sorted"]}>
              <button
                type="button"
                phx-click="sort"
                phx-value-by="name"
                class={[
                  "inline-flex items-center gap-1.5 hover:text-ink-1",
                  @sort_by == "name" && "text-accent"
                ]}
              >
                Name
                <span class="text-accent text-[10px]">
                  {sort_caret("name", @sort_by, @sort_order)}
                </span>
              </button>
            </th>
            <th class={["text-right", @sort_by == "score" && "is-sorted"]}>
              <button
                type="button"
                phx-click="sort"
                phx-value-by="score"
                class={[
                  "inline-flex items-center gap-1.5 hover:text-ink-1",
                  @sort_by == "score" && "text-accent"
                ]}
              >
                Score
                <span class="text-accent text-[10px]">
                  {sort_caret("score", @sort_by, @sort_order)}
                </span>
              </button>
            </th>
            <th class={["text-right", @sort_by == "price" && "is-sorted"]}>
              <button
                type="button"
                phx-click="sort"
                phx-value-by="price"
                class={[
                  "inline-flex items-center gap-1.5 hover:text-ink-1",
                  @sort_by == "price" && "text-accent"
                ]}
              >
                Price (ISK)
                <span class="text-accent text-[10px]">
                  {sort_caret("price", @sort_by, @sort_order)}
                </span>
              </button>
            </th>
            <th>Attributes</th>
          </tr>
        </thead>
        <tbody>
          <%!-- S-tier section: rows scoring >= 0.85, set apart with a mono label divider. --%>
          <%= if Enum.any?(@s_tier_modules) do %>
            <tr class="s-tier-divider" aria-hidden="true">
              <td colspan="5">
                <span class="s-tier-divider-label">
                  S-tier · {length(@s_tier_modules)} match{if length(@s_tier_modules) == 1,
                    do: "",
                    else: "es"}
                </span>
              </td>
            </tr>
            <%= for entry <- @s_tier_modules do %>
              <.result_row
                entry={entry}
                top_entry={@top_entry}
                selected_module={@selected_module}
                median_price={@median_price}
                radar_attrs={@radar_attrs}
                attr_ranges={@attr_ranges}
                attr_directions={@attr_directions}
                s_tier={true}
              />
            <% end %>
            <%= if Enum.any?(@rest_modules) do %>
              <tr class="s-tier-divider" aria-hidden="true">
                <td colspan="5">
                  <span class="s-tier-divider-label" style="--accent-line-color: var(--rule-strong);">
                    Rest · {length(@rest_modules)}
                  </span>
                </td>
              </tr>
            <% end %>
          <% end %>

          <%= for entry <- @rest_modules do %>
            <.result_row
              entry={entry}
              top_entry={@top_entry}
              selected_module={@selected_module}
              median_price={@median_price}
              radar_attrs={@radar_attrs}
              attr_ranges={@attr_ranges}
              attr_directions={@attr_directions}
              s_tier={false}
            />
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :entry, :any, required: true
  attr :top_entry, :any, required: true
  attr :selected_module, :any, required: true
  attr :median_price, :any, required: true
  attr :radar_attrs, :list, required: true
  attr :attr_ranges, :map, required: true
  attr :attr_directions, :map, default: %{}
  attr :s_tier, :boolean, required: true

  defp result_row(assigns) do
    module = assigns.entry.module
    score = assigns.entry.score
    row_id = module_dom_id(assigns.entry)
    is_top = assigns.top_entry == assigns.entry

    is_selected =
      assigns.selected_module && module_dom_id(assigns.selected_module) == row_id

    price = module[:price] || module.price
    is_deal = price_below?(price, assigns.median_price)

    radar_values =
      radar_normalize(module, assigns.radar_attrs, assigns.attr_ranges, assigns.attr_directions)

    assigns =
      assigns
      |> assign(:module, module)
      |> assign(:score, score)
      |> assign(:row_id, row_id)
      |> assign(:is_top, is_top)
      |> assign(:is_selected, is_selected)
      |> assign(:price, price)
      |> assign(:is_deal, is_deal)
      |> assign(:radar_values, radar_values)
      |> assign(:radar_polygon, radar_data_points(radar_values))

    ~H"""
    <tr
      id={@row_id}
      phx-click="select_row"
      phx-value-id={@row_id}
      class={[
        "cursor-pointer",
        @is_selected && "is-selected"
      ]}
    >
      <td class="text-center text-ink-3 text-[11px]" aria-hidden="true">
        <%= if @is_top do %>
          ▸
        <% else %>
        <% end %>
      </td>
      <td>
        <div class="font-medium text-ink-1">{@module[:name] || @module.name}</div>
        <div class="text-[11px] text-ink-3">
          {@module[:type_name] || @module[:source_type_name] || @module.type_name}
        </div>
      </td>
      <td class={["text-right", (@score || 0) >= 0.85 && "is-strong"]}>
        <div class="inline-flex items-center justify-end gap-2.5">
          <span class={["score-hero", score_tier_class(@score)]}>
            {format_score(@score)}
          </span>
          <%= if Enum.any?(@radar_values) do %>
            <svg
              class={["score-radar", @s_tier && "is-s-tier"]}
              viewBox="-160 -160 320 320"
              aria-hidden="true"
            >
              <polygon points={radar_grid_points(150)} class="score-radar-grid" />
              <polygon points={@radar_polygon} class="score-radar-shape" />
            </svg>
          <% else %>
            <span class={["score-hero-bar", score_tier_class(@score)]}>
              <span style={"width: #{round((@score || 0) * 100)}%"} />
            </span>
          <% end %>
        </div>
      </td>
      <td class="text-right tnum">
        <div class="inline-flex items-center justify-end gap-2">
          <span :if={@is_deal} class="pill-deal" title="Below median price">Deal</span>
          {format_price(@price)}
        </div>
      </td>
      <td>
        <div class="text-[11px] text-ink-3 truncate max-w-[280px]">
          <%= for {{attr, value}, idx} <- Enum.with_index(Enum.take(@module[:attributes] || @module.attributes || %{}, 3)) do %>
            <span :if={idx > 0} class="text-ink-4 mx-1.5">·</span>
            <span>{humanize(attr)}</span>
            <span class="text-ink-2 tnum ml-1">{format_attribute_value(value)}</span>
          <% end %>
        </div>
      </td>
    </tr>
    """
  end

  # ── Detail drawer ───────────────────────────────────────────────────

  attr :entry, :map, required: true
  attr :module_type, :any, required: true
  attr :filters, :map, required: true
  attr :copy_state, :atom, required: true

  defp detail_drawer(assigns) do
    module = assigns.entry.module
    score = assigns.entry.score

    assigns =
      assigns
      |> assign(:module, module)
      |> assign(:score, score)
      |> assign(:contract, contract_url(assigns.entry))
      |> assign(:attrs, module[:attributes] || module.attributes || %{})

    ~H"""
    <div
      id="drawer"
      class="fixed inset-y-0 right-0 w-full max-w-[400px] z-30 flex flex-col bg-surface-1 border-l border-rule-1"
      style="box-shadow: -8px 0 24px oklch(0 0 0 / 0.35)"
      role="complementary"
      aria-label="Module details"
    >
      <header class="flex items-start justify-between gap-3 px-5 py-4 border-b border-rule-1">
        <div class="min-w-0">
          <p class="text-[11px] uppercase tracking-wider text-ink-3 font-medium">
            {@module[:type_name] || @module[:source_type_name] || (@module_type && @module_type.name)}
          </p>
          <h2 class="text-[17px] font-semibold text-ink-1 leading-snug truncate mt-0.5">
            {@module[:name] || @module.name}
          </h2>
        </div>
        <button
          type="button"
          phx-click="close_drawer"
          class="text-ink-3 hover:text-ink-1 -mt-1 -mr-1 p-2"
          aria-label="Close details"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </header>

      <div class="px-5 py-4 grid grid-cols-2 gap-4 border-b border-rule-1">
        <div>
          <p class="text-[11px] uppercase tracking-wider text-ink-3 font-medium">Score</p>
          <p class={[
            "mt-1 text-[28px] font-semibold tnum leading-none",
            score_tier_text_class(@score)
          ]}>
            {format_score(@score)}
          </p>
          <span
            class={["block mt-2 score-hero-bar w-full", score_tier_class(@score)]}
            style="width: 100%; height: 4px;"
          >
            <span style={"width: #{round((@score || 0) * 100)}%"} />
          </span>
        </div>
        <div>
          <p class="text-[11px] uppercase tracking-wider text-ink-3 font-medium">Price</p>
          <p class="mt-1 text-[15px] text-ink-1 tnum">
            {format_price(@module[:price] || @module.price)}
          </p>
          <p :if={@module[:station_name] || @module[:region_name]} class="mt-1 text-[12px] text-ink-3">
            {@module[:station_name] || @module[:region_name]}
          </p>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto">
        <ul class="divide-y divide-rule-1">
          <%= for {attr, value} <- Enum.sort_by(@attrs, fn {k, _} -> humanize(k) end) do %>
            <% meta = attribute_meta(@module_type, attr)

            numeric_value =
              numeric(
                case value do
                  %{"value" => v} -> v
                  v -> v
                end
              )

            pct = meta && percent_position(numeric_value, meta) %>
            <li class="px-5 py-3">
              <div class="flex items-baseline justify-between gap-3">
                <span class="text-[13px] text-ink-2 truncate">{humanize(attr)}</span>
                <span class="text-[13px] text-ink-1 tnum shrink-0">
                  {format_attribute_value(value)}
                </span>
              </div>
              <div :if={pct} class="mt-2 flex items-center gap-2 text-[11px] text-ink-4 tnum">
                <span>{format_attribute_value(meta.min)}</span>
                <span class="relative flex-1 h-1 bg-surface-3 rounded-sm">
                  <span
                    class="absolute top-1/2 -translate-y-1/2 block h-2 w-0.5 bg-accent"
                    style={"left: #{pct}%"}
                  />
                </span>
                <span>{format_attribute_value(meta.max)}</span>
              </div>
            </li>
          <% end %>
        </ul>
      </div>

      <footer class="flex items-center gap-2 px-5 py-3 border-t border-rule-1">
        <button
          :if={@contract}
          type="button"
          phx-click="copy_contract"
          phx-hook=".CopyContract"
          data-contract-url={@contract}
          id="copy-contract-btn"
          class="btn btn-primary flex-1"
        >
          {if @copy_state == :copied, do: "Copied", else: "Copy contract"}
        </button>
        <span :if={!@contract} class="text-[12px] text-ink-4 flex-1">
          No contract URL provided.
        </span>
        <.link
          :if={@module_type}
          navigate={watch_url(@module_type, @filters)}
          class="btn btn-ghost"
          title="Create a watchlist for this module type"
        >
          <.icon name="hero-bell-alert" class="size-4" /> Watch
        </.link>
        <a
          :if={@contract}
          href={@contract}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-ghost"
        >
          Open <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </a>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyContract">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const url = this.el.dataset.contractUrl
                if (url && navigator.clipboard) navigator.clipboard.writeText(url)
              })
            }
          }
        </script>
      </footer>
    </div>
    """
  end

  # ── Leaf format helpers ─────────────────────────────────────────────

  defp format_price(nil), do: "—"

  defp format_price(%Decimal{} = price) do
    price
    |> Decimal.round(0)
    |> Decimal.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_price(price) when is_number(price) do
    format_price(Decimal.new(round(price)))
  end

  defp format_price(_), do: "—"

  defp safe_existing_atom(value) when is_atom(value), do: value

  defp safe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp safe_existing_atom(_), do: nil

  defp format_attribute_value(value) when is_float(value) do
    rounded = Float.round(value, 2)

    if rounded == Float.round(rounded, 0) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 2)
    end
  end

  defp format_attribute_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_attribute_value(%{"value" => v}), do: format_attribute_value(v)
  defp format_attribute_value(%{value: v}), do: format_attribute_value(v)

  defp format_attribute_value(nil), do: "—"

  defp format_attribute_value(value) when is_binary(value) do
    case Float.parse(value) do
      {f, ""} -> format_attribute_value(f)
      _ -> value
    end
  end

  defp format_attribute_value(value), do: to_string(value)

  # ── Hero radar geometry ────────────────────────────────────────────
  # Five-axis radar plotted on a 320×320 viewBox centered at (0,0).
  # Axis 0 is up (-y), then clockwise. Used by the empty-state hero art.

  @radar_axes_count 5
  @radar_max_radius 150

  defp radar_grid_points(radius) do
    values = for _ <- 1..@radar_axes_count, do: 1.0
    radar_polygon_points(values, radius: radius)
  end

  defp radar_data_points(values) when is_list(values) do
    radar_polygon_points(values, radius: @radar_max_radius)
  end

  defp radar_polygon_points(values, opts) do
    radius = Keyword.fetch!(opts, :radius)

    values
    |> radar_coords(radius)
    |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
  end

  defp radar_axes do
    radar_coords(List.duplicate(1.0, @radar_axes_count), @radar_max_radius)
  end

  defp radar_vertex_dots(values), do: radar_coords(values, @radar_max_radius)

  defp radar_coords(values, radius) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      angle = -:math.pi() / 2 + i * (2 * :math.pi() / @radar_axes_count)
      r = v * radius
      x = r * :math.cos(angle)
      y = r * :math.sin(angle)
      {Float.round(x, 2), Float.round(y, 2)}
    end)
  end

  # ── Per-row analytics for the results table ────────────────────────
  # Median, top-N attribute selection, normalization for the score-radar.

  defp compute_median_price([]), do: nil

  defp compute_median_price(modules) do
    prices =
      modules
      |> Enum.map(fn %{module: m} -> m[:price] || m.price end)
      |> Enum.map(&price_to_float/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case length(prices) do
      0 -> nil
      n when rem(n, 2) == 1 -> Enum.at(prices, div(n, 2))
      n -> (Enum.at(prices, div(n, 2) - 1) + Enum.at(prices, div(n, 2))) / 2
    end
  end

  defp price_to_float(nil), do: nil
  defp price_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp price_to_float(n) when is_number(n), do: n * 1.0
  defp price_to_float(_), do: nil

  defp price_below?(nil, _), do: false
  defp price_below?(_, nil), do: false

  defp price_below?(price, median) do
    case price_to_float(price) do
      nil -> false
      f -> f < median
    end
  end

  # Partition results into "standout" S-tier and the rest. The naive
  # threshold (score >= 0.85) over-fires when the upstream feed is
  # uniformly high-scoring (every roll an S-tier removes the signal),
  # so we cap S-tier at 10% of the result set or 25 rows, whichever is
  # smaller. Below 8 results, no partition — the divider would be noise.
  defp partition_s_tier(modules) when length(modules) < 8, do: {[], modules}

  defp partition_s_tier(modules) do
    n = length(modules)
    cap = min(25, max(1, div(n, 10)))
    sorted = Enum.sort_by(modules, fn %{score: s} -> s || 0 end, :desc)

    case Enum.take(sorted, cap) do
      [] ->
        {[], modules}

      candidates ->
        # Only call them S-tier if they actually clear the absolute bar.
        s_tier = Enum.filter(candidates, fn %{score: s} -> (s || 0) >= 0.85 end)

        if Enum.empty?(s_tier) do
          {[], modules}
        else
          ids = MapSet.new(Enum.map(s_tier, & &1))
          rest = Enum.reject(modules, &MapSet.member?(ids, &1))
          # Preserve the user's chosen sort within s_tier.
          ordered = Enum.filter(modules, &MapSet.member?(ids, &1))
          {ordered, rest}
        end
    end
  end

  # Pick up to 5 attributes that are most commonly present across the
  # result set. Used as the radar's axes — keeps the visual stable as
  # the user changes scoring/filters within a single result set.
  defp pick_radar_attributes([]), do: []

  defp pick_radar_attributes(modules) do
    modules
    |> Enum.flat_map(fn %{module: m} ->
      attrs = m[:attributes] || m.attributes || %{}
      Map.keys(attrs)
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_k, count} -> -count end)
    |> Enum.take(5)
    |> Enum.map(fn {k, _} -> k end)
  end

  # For each picked attribute, compute the {min, max} numeric range
  # across the result set so per-row values can be normalized to 0..1.
  defp compute_attr_ranges([], _attrs), do: %{}

  defp compute_attr_ranges(modules, attrs) do
    Enum.reduce(attrs, %{}, fn attr, acc ->
      values =
        modules
        |> Enum.map(fn %{module: m} ->
          attrs_map = m[:attributes] || m.attributes || %{}
          numeric_attr_value(Map.get(attrs_map, attr))
        end)
        |> Enum.reject(&is_nil/1)

      case values do
        [] -> Map.put(acc, attr, {0.0, 1.0})
        [single] -> Map.put(acc, attr, {single, single})
        list -> Map.put(acc, attr, {Enum.min(list), Enum.max(list)})
      end
    end)
  end

  # Map a per-row {attr -> value} pair onto a 0..1 normalized list of
  # length len(attrs), in the same order as `attrs`. Constant attributes
  # (range collapsed to a point) emit 0.5 — neutral — to avoid spikes.
  # For "lower_better" attributes (e.g. cpu_usage, activation_cost), the
  # normalized ratio is inverted so a smaller raw value still produces a
  # longer spoke — visually consistent with "more spoke = better".
  defp radar_normalize(_module, [], _ranges, _directions), do: []

  defp radar_normalize(module, attrs, ranges, directions) do
    attrs_map = module[:attributes] || module.attributes || %{}

    Enum.map(attrs, fn attr ->
      value = numeric_attr_value(Map.get(attrs_map, attr))
      {min_v, max_v} = Map.get(ranges, attr, {0.0, 1.0})

      cond do
        is_nil(value) ->
          0.0

        max_v == min_v ->
          0.5

        true ->
          ratio = max(0.0, min(1.0, (value - min_v) / (max_v - min_v)))

          case Map.get(directions, attr, "higher_better") do
            "lower_better" -> 1.0 - ratio
            _ -> ratio
          end
      end
    end)
  end

  # Build an attribute -> direction map for the picked radar axes from
  # the selected module type's metadata. Falls back to higher_better for
  # any attribute not in the metadata.
  defp compute_attr_directions(nil, _attrs), do: %{}

  defp compute_attr_directions(module_type, attrs) do
    base_attrs = module_type.base_attributes || %{}

    Enum.reduce(attrs, %{}, fn attr, acc ->
      key = to_string(attr)
      direction = get_in(base_attrs, [key, "direction"]) || "higher_better"
      Map.put(acc, attr, direction)
    end)
  end

  defp numeric_attr_value(nil), do: nil
  defp numeric_attr_value(v) when is_number(v), do: v * 1.0
  defp numeric_attr_value(%{"value" => v}), do: numeric_attr_value(v)
  defp numeric_attr_value(%{value: v}), do: numeric_attr_value(v)

  defp numeric_attr_value(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp numeric_attr_value(_), do: nil
end
