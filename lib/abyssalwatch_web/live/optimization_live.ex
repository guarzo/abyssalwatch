defmodule AbyssalwatchWeb.OptimizationLive do
  @moduledoc """
  Single-page abyssal-module optimizer.

  The pilot pastes an EFT (or drops the file in), the surface auto-derives
  the included module types from the fit, and the sidebar tunes constraints,
  objectives, and solver mode. Optimize fills the slots; the solutions table
  ranks results, and the selected detail panel shows the slot-by-slot
  assignment.

  See DESIGN.md and PRODUCT.md for the visual language.
  """

  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Fittings.Parsers.EFT
  alias Abyssalwatch.Optimization
  alias Abyssalwatch.Optimization.Types.Constraints
  alias Abyssalwatch.Market.ModuleType
  alias Abyssalwatch.Market.Scoring.{Topsis, Criteria}
  alias Abyssalwatch.Market.Mutamarket.Client, as: MutamarketClient

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active, :optimize)
     |> assign(:fitting, nil)
     |> assign(:eft_input, "")
     |> assign(:eft_error, nil)
     |> assign(:constraints, default_constraints())
     |> assign(:criteria, Criteria.default())
     |> assign(:solver_mode, :heuristic)
     |> assign(:module_types, load_module_types())
     |> assign(:included_type_ids, [])
     |> assign(:types_popover_open, false)
     |> assign(:type_filter, "")
     |> assign(:candidates, [])
     |> assign(:loading_modules, false)
     |> assign(:optimizing, false)
     |> assign(:optimization_start_time, nil)
     |> assign(:optimization_elapsed, 0)
     |> assign(:optimization_error, nil)
     |> assign(:optimization_timer_ref, nil)
     |> assign(:solutions, [])
     |> assign(:selected_solution, nil)
     |> assign(:expanded_module_id, nil)
     |> assign(:copy_state, :idle)
     |> assign(:confirming_clear, false)
     |> allow_upload(:eft_file,
       accept: ~w(.txt .eft),
       max_entries: 1,
       max_file_size: 100_000
     )}
  end

  # ── Import ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("update_eft_input", %{"eft" => eft_text}, socket) do
    {:noreply, assign(socket, :eft_input, eft_text)}
  end

  @impl true
  def handle_event("parse_eft", _params, socket) do
    parse_and_load(socket, socket.assigns.eft_input)
  end

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("upload_eft", _params, socket) do
    contents =
      consume_uploaded_entries(socket, :eft_file, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case contents do
      [eft_text | _] -> parse_and_load(socket, eft_text)
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :eft_file, ref)}
  end

  @impl true
  def handle_event("clear_fitting", _params, socket) do
    if Enum.any?(socket.assigns.solutions) and not socket.assigns.confirming_clear do
      {:noreply, assign(socket, :confirming_clear, true)}
    else
      {:noreply, reset_to_empty(socket)}
    end
  end

  @impl true
  def handle_event("cancel_clear", _params, socket) do
    {:noreply, assign(socket, :confirming_clear, false)}
  end

  # ── Tune ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("update_constraints", params, socket) do
    constraints = %Constraints{
      cpu_capacity: parse_float(params["cpu_capacity"], socket.assigns.constraints.cpu_capacity),
      power_capacity:
        parse_float(params["power_capacity"], socket.assigns.constraints.power_capacity),
      calibration_capacity:
        parse_float(
          params["calibration_capacity"],
          socket.assigns.constraints.calibration_capacity
        ),
      available_slots: %{
        high: parse_int(params["high_slots"], socket.assigns.constraints.available_slots.high),
        med: parse_int(params["med_slots"], socket.assigns.constraints.available_slots.med),
        low: parse_int(params["low_slots"], socket.assigns.constraints.available_slots.low),
        rig: parse_int(params["rig_slots"], socket.assigns.constraints.available_slots.rig)
      },
      max_price: parse_decimal(params["max_price"])
    }

    {:noreply, assign(socket, :constraints, constraints)}
  end

  @impl true
  def handle_event("update_objective", %{"key" => key, "value" => raw}, socket) do
    weight = parse_float(raw, 0.5)
    criteria = put_criteria_weight(socket.assigns.criteria, key, weight)
    {:noreply, assign(socket, :criteria, criteria)}
  end

  @impl true
  def handle_event("update_solver_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :solver_mode, normalize_solver(mode))}
  end

  # ── Module-types popover ──────────────────────────────────────────

  @impl true
  def handle_event("toggle_types_popover", _params, socket) do
    {:noreply,
     socket
     |> assign(:types_popover_open, not socket.assigns.types_popover_open)
     |> assign(:type_filter, "")}
  end

  @impl true
  def handle_event("close_types_popover", _params, socket) do
    {:noreply, assign(socket, :types_popover_open, false)}
  end

  @impl true
  def handle_event("filter_types", %{"q" => q}, socket) do
    {:noreply, assign(socket, :type_filter, q)}
  end

  @impl true
  def handle_event("toggle_module_type", %{"type_id" => raw}, socket) do
    type_id = String.to_integer(raw)
    included = socket.assigns.included_type_ids

    next =
      if type_id in included, do: List.delete(included, type_id), else: [type_id | included]

    {:noreply, assign(socket, :included_type_ids, next)}
  end

  @impl true
  def handle_event("reset_types_to_fit", _params, socket) do
    {:noreply, assign(socket, :included_type_ids, derive_types_from_fit(socket.assigns))}
  end

  # ── Run ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("optimize", _params, socket) do
    cond do
      is_nil(socket.assigns.fitting) ->
        {:noreply, socket}

      Enum.empty?(socket.assigns.included_type_ids) ->
        {:noreply, put_flash(socket, :error, "Include at least one module type to optimize")}

      true ->
        cancel_optimization_timer(socket.assigns[:optimization_timer_ref])
        {:ok, timer_ref} = :timer.send_interval(120, self(), :optimization_tick)

        socket =
          socket
          |> assign(:loading_modules, true)
          |> assign(:optimizing, true)
          |> assign(:optimization_error, nil)
          |> assign(:optimization_start_time, System.monotonic_time(:millisecond))
          |> assign(:optimization_elapsed, 0)
          |> assign(:optimization_timer_ref, timer_ref)

        send(self(), :load_candidates)
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_optimize", _params, socket) do
    # UI-side cancel: hide running state. The underlying solver continues
    # but its result is discarded by ignoring late :optimization_done sends.
    cancel_optimization_timer(socket.assigns[:optimization_timer_ref])

    {:noreply,
     socket
     |> assign(:loading_modules, false)
     |> assign(:optimizing, false)
     |> assign(:optimization_elapsed, 0)
     |> assign(:optimization_timer_ref, nil)}
  end

  @impl true
  def handle_event("select_solution", %{"index" => raw}, socket) do
    index = String.to_integer(raw)

    {:noreply,
     socket
     |> assign(:selected_solution, Enum.at(socket.assigns.solutions, index))
     |> assign(:expanded_module_id, nil)}
  end

  @impl true
  def handle_event("toggle_module_detail", %{"module-id" => id}, socket) do
    current = socket.assigns.expanded_module_id
    next = if current == id, do: nil, else: id
    {:noreply, assign(socket, :expanded_module_id, next)}
  end

  # ── Export ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("export_eft", _params, socket), do: do_export_text(socket, :eft)
  def handle_event("export_json", _params, socket), do: do_export_text(socket, :json)

  @impl true
  def handle_event("export_all_json", _params, socket) do
    case socket.assigns do
      %{solutions: []} ->
        {:noreply, socket}

      %{fitting: nil} ->
        {:noreply, socket}

      assigns ->
        ship = assigns.fitting.ship_type
        name = "#{assigns.fitting.name} (Optimized)"
        json = Optimization.export_solutions_to_json(assigns.solutions, ship, name)
        json_string = Jason.encode!(json, pretty: true)

        {:noreply,
         push_event(socket, "download_file", %{
           content: json_string,
           filename: "#{name}.json",
           type: "application/json"
         })}
    end
  end

  # ── Keyboard ──────────────────────────────────────────────────────

  @impl true
  def handle_event("keydown", %{"key" => key} = params, socket) do
    ctrl = Map.get(params, "ctrlKey", false)
    meta = Map.get(params, "metaKey", false)

    cond do
      key == "Escape" and socket.assigns.types_popover_open ->
        {:noreply, assign(socket, :types_popover_open, false)}

      key == "Escape" and socket.assigns.confirming_clear ->
        {:noreply, assign(socket, :confirming_clear, false)}

      key == "Enter" and (ctrl or meta) and socket.assigns.fitting and
          not socket.assigns.optimizing ->
        handle_event("optimize", %{}, socket)

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:load_candidates, socket) do
    module_types = socket.assigns.module_types
    criteria = socket.assigns.criteria

    candidates =
      socket.assigns.included_type_ids
      |> Task.async_stream(
        fn type_id ->
          type = Enum.find(module_types, &(&1.eve_type_id == type_id))
          slot_type = get_slot_type(type)

          case MutamarketClient.search_modules(type_id) do
            {:ok, modules} ->
              merged = Criteria.merge_with_module_type(criteria, type)
              scored = Topsis.score(modules, merged)
              Optimization.prepare_candidates(scored, slot_type)

            {:error, _} ->
              []
          end
        end,
        max_concurrency: 8,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, list} -> list
        _ -> []
      end)

    socket = assign(socket, :candidates, candidates) |> assign(:loading_modules, false)
    send(self(), :run_optimization)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:run_optimization, socket) do
    case Optimization.optimize(
           socket.assigns.candidates,
           socket.assigns.constraints,
           mode: socket.assigns.solver_mode
         ) do
      {:ok, %{solutions: solutions}} ->
        if socket.assigns.optimizing do
          cancel_optimization_timer(socket.assigns[:optimization_timer_ref])

          {:noreply,
           socket
           |> assign(:solutions, solutions)
           |> assign(:selected_solution, List.first(solutions))
           |> assign(:optimizing, false)
           |> assign(:optimization_elapsed, 0)
           |> assign(:optimization_timer_ref, nil)}
        else
          # Cancelled UI-side; discard.
          {:noreply, socket}
        end

      {:error, reason} ->
        cancel_optimization_timer(socket.assigns[:optimization_timer_ref])

        {:noreply,
         socket
         |> assign(:optimization_error, format_solver_error(reason))
         |> assign(:optimizing, false)
         |> assign(:optimization_elapsed, 0)
         |> assign(:optimization_timer_ref, nil)}
    end
  end

  @impl true
  def handle_info(:optimization_tick, socket) do
    if socket.assigns.optimizing do
      elapsed = System.monotonic_time(:millisecond) - socket.assigns.optimization_start_time
      {:noreply, assign(socket, :optimization_elapsed, elapsed)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:clear_copy_state, socket) do
    {:noreply, assign(socket, :copy_state, :idle)}
  end

  # ── Internal helpers ──────────────────────────────────────────────

  defp parse_and_load(socket, eft_text) do
    case EFT.parse(eft_text) do
      {:ok, fitting} ->
        socket =
          socket
          |> assign(:fitting, fitting)
          |> assign(:eft_input, eft_text)
          |> assign(:eft_error, nil)
          |> assign(:solutions, [])
          |> assign(:selected_solution, nil)
          |> assign(:optimization_error, nil)
          |> assign(:confirming_clear, false)

        included = derive_types_from_fit(socket.assigns)
        {:noreply, assign(socket, :included_type_ids, included)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:fitting, nil)
         |> assign(:eft_error, to_string(reason))
         |> assign(:included_type_ids, [])
         |> assign(:solutions, [])
         |> assign(:selected_solution, nil)
         |> assign(:expanded_module_id, nil)
         |> assign(:optimization_error, nil)
         |> assign(:confirming_clear, false)}
    end
  end

  defp reset_to_empty(socket) do
    socket
    |> assign(:fitting, nil)
    |> assign(:eft_input, "")
    |> assign(:eft_error, nil)
    |> assign(:included_type_ids, [])
    |> assign(:candidates, [])
    |> assign(:solutions, [])
    |> assign(:selected_solution, nil)
    |> assign(:optimization_error, nil)
    |> assign(:confirming_clear, false)
  end

  defp do_export_text(%{assigns: %{selected_solution: nil}} = socket, _format),
    do: {:noreply, socket}

  defp do_export_text(%{assigns: %{fitting: nil}} = socket, _format), do: {:noreply, socket}

  defp do_export_text(socket, format) do
    solution = socket.assigns.selected_solution
    ship = socket.assigns.fitting.ship_type
    name = "#{socket.assigns.fitting.name} (Optimized)"

    text =
      case format do
        :eft ->
          Optimization.export_to_eft(solution, ship, name)

        :json ->
          solution
          |> Optimization.export_to_json()
          |> Jason.encode!(pretty: true)
      end

    Process.send_after(self(), :clear_copy_state, 1200)

    {:noreply,
     socket
     |> assign(:copy_state, format)
     |> push_event("copy_to_clipboard", %{text: text})}
  end

  defp load_module_types do
    case Ash.read(ModuleType) do
      {:ok, types} -> Enum.sort_by(types, & &1.name)
      {:error, _} -> []
    end
  end

  defp default_constraints do
    Constraints.new(%{
      cpu_capacity: 400.0,
      power_capacity: 1000.0,
      calibration_capacity: 400.0,
      available_slots: %{high: 4, med: 4, low: 4, rig: 3}
    })
  end

  defp cancel_optimization_timer(nil), do: :ok
  defp cancel_optimization_timer(ref), do: :timer.cancel(ref)

  @impl true
  def terminate(_reason, socket) do
    cancel_optimization_timer(socket.assigns[:optimization_timer_ref])
    :ok
  end

  defp derive_types_from_fit(%{fitting: nil}), do: []

  defp derive_types_from_fit(%{fitting: fit, module_types: types}) do
    fit_module_names =
      [fit.low_slots, fit.med_slots, fit.high_slots, fit.rig_slots]
      |> List.flatten()
      |> Enum.map(&module_name/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    types
    |> Enum.filter(fn t ->
      base = String.replace_prefix(t.name, "Abyssal ", "")

      MapSet.member?(fit_module_names, t.name) or
        Enum.any?(fit_module_names, fn fit_name ->
          String.contains?(fit_name, t.name) or String.contains?(fit_name, base)
        end)
    end)
    |> Enum.map(& &1.eve_type_id)
  end

  defp module_name(%{name: name}), do: name
  defp module_name(name) when is_binary(name), do: name
  defp module_name(_), do: nil

  defp put_criteria_weight(criteria, key, value) do
    field =
      case key do
        "price" -> :price_weight
        "performance" -> :performance_weight
        "efficiency" -> :efficiency_weight
        "volume" -> :volume_weight
        _ -> nil
      end

    if field, do: Map.put(criteria, field, value), else: criteria
  end

  defp normalize_solver("constraint"), do: :constraint
  defp normalize_solver(_), do: :heuristic

  defp get_slot_type(nil), do: :low
  defp get_slot_type(%{slot_type: "high"}), do: :high
  defp get_slot_type(%{slot_type: "med"}), do: :med
  defp get_slot_type(%{slot_type: "low"}), do: :low
  defp get_slot_type(%{slot_type: "rig"}), do: :rig

  defp get_slot_type(%{category: c}) do
    cd = String.downcase(c || "")

    cond do
      String.contains?(cd, "propulsion") -> :med
      String.contains?(cd, "shield") -> :med
      String.contains?(cd, "armor") -> :low
      String.contains?(cd, "damage") -> :low
      true -> :low
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(value, _default) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(value, _) when is_number(value), do: value / 1.0
  defp parse_float(_, default), do: default

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp parse_int(value, _) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp parse_decimal(_), do: nil

  defp format_solver_error(reason) when is_binary(reason), do: reason
  defp format_solver_error(reason), do: inspect(reason)

  defp upload_error(:too_large), do: "File is too large (max 100KB)"
  defp upload_error(:too_many_files), do: "Only one file allowed"
  defp upload_error(:not_accepted), do: "Use .txt or .eft files"
  defp upload_error(err), do: "Upload error: #{inspect(err)}"

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    abyssal_count =
      if assigns.fitting, do: count_abyssal_slots(assigns.fitting), else: 0

    assigns = assign(assigns, :abyssal_count, abyssal_count)

    ~H"""
    <div
      id="optimize-root"
      phx-window-keydown="keydown"
      class="flex flex-col gap-6"
    >
      <.fitting_strip
        fitting={@fitting}
        eft_input={@eft_input}
        eft_error={@eft_error}
        uploads={@uploads}
        confirming_clear={@confirming_clear}
        abyssal_count={@abyssal_count}
        solution_count={length(@solutions)}
      />

      <div class="grid gap-6 lg:grid-cols-[320px_minmax(0,1fr)] lg:gap-8">
        <.tune_sidebar
          fitting={@fitting}
          constraints={@constraints}
          criteria={@criteria}
          solver_mode={@solver_mode}
          included_type_ids={@included_type_ids}
          module_types={@module_types}
          types_popover_open={@types_popover_open}
          type_filter={@type_filter}
        />

        <div class="min-w-0 space-y-4">
          <.runbar
            fitting={@fitting}
            included_type_ids={@included_type_ids}
            solver_mode={@solver_mode}
            optimizing={@optimizing}
            loading_modules={@loading_modules}
            optimization_elapsed={@optimization_elapsed}
            optimization_error={@optimization_error}
          />

          <.solutions_panel
            fitting={@fitting}
            solutions={@solutions}
            selected_solution={@selected_solution}
            optimizing={@optimizing}
            constraints={@constraints}
            copy_state={@copy_state}
            expanded_module_id={@expanded_module_id}
          />
        </div>
      </div>
    </div>
    """
  end

  # ── Fitting strip ──────────────────────────────────────────────────

  attr :fitting, :any, required: true
  attr :eft_input, :string, required: true
  attr :eft_error, :any, required: true
  attr :uploads, :map, required: true
  attr :confirming_clear, :boolean, required: true
  attr :abyssal_count, :integer, required: true
  attr :solution_count, :integer, required: true

  defp fitting_strip(assigns) do
    ~H"""
    <%= if @fitting do %>
      <div class="panel">
        <div class="px-5 py-3 flex items-center justify-between gap-4">
          <div class="flex items-baseline gap-3 min-w-0">
            <span class="text-ink-1 font-medium truncate">{@fitting.ship_type}</span>
            <span class="text-ink-3 text-[13px] truncate">· {@fitting.name}</span>
            <span class="text-ink-4 text-[12px] tnum shrink-0">
              · {@abyssal_count} abyssal {pluralize(@abyssal_count, "slot", "slots")}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <%= if @confirming_clear do %>
              <span class="text-[12px] text-ink-3 tnum">
                Discard {@solution_count} {pluralize(@solution_count, "solution", "solutions")}?
              </span>
              <button
                type="button"
                class="btn btn-sm btn-danger"
                phx-click="clear_fitting"
              >
                Clear
              </button>
              <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel_clear">
                Keep
              </button>
            <% else %>
              <button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="clear_fitting"
              >
                <.icon name="hero-x-mark" class="size-4" /> Clear fit
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% else %>
      <div class="panel">
        <div class="px-5 py-5">
          <div class="flex items-baseline justify-between mb-3">
            <h2 class="text-[15px] font-semibold text-ink-1">
              Paste an EFT to begin
            </h2>
            <label class="text-[12px] text-ink-3 hover:text-ink-1 cursor-pointer">
              Or upload .eft <.live_file_input upload={@uploads.eft_file} class="sr-only" />
            </label>
          </div>

          <form phx-change="update_eft_input" phx-submit="parse_eft" id="eft-form">
            <textarea
              id="eft-paste"
              name="eft"
              phx-debounce="300"
              class="textarea font-mono text-[12px] leading-snug"
              style="min-height: 96px; max-height: 320px;"
              placeholder={eft_placeholder()}
              phx-hook=".PasteParse"
            ><%= @eft_input %></textarea>
          </form>

          <%= if @eft_error do %>
            <div class="mt-3 flex items-start gap-2 text-status-error text-[13px]">
              <span class="mt-0.5" aria-hidden="true">!</span>
              <div class="flex-1">
                <p class="text-ink-1">EFT parse failed</p>
                <p class="text-ink-3 text-[12px]">{@eft_error}</p>
              </div>
            </div>
          <% end %>

          <%= for entry <- @uploads.eft_file.entries do %>
            <div class="mt-3 flex items-center gap-2 text-[12px] text-ink-3">
              <span class="truncate flex-1">{entry.client_name}</span>
              <span class="tnum">{entry.progress}%</span>
              <button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
              >
                Cancel
              </button>
            </div>
            <%= for err <- upload_errors(@uploads.eft_file, entry) do %>
              <p class="mt-1 text-status-error text-[12px]">{upload_error(err)}</p>
            <% end %>
          <% end %>

          <div class="mt-3 flex items-center justify-between">
            <p class="text-[11px] text-ink-4">
              Drop a .eft file on the textarea, or paste then press Ctrl-Enter.
            </p>
            <button
              type="button"
              class="btn btn-primary btn-sm"
              phx-click="parse_eft"
              disabled={String.trim(@eft_input) == ""}
            >
              Load fitting
            </button>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".PasteParse">
            export default {
              mounted() {
                const ta = this.el
                ta.addEventListener("keydown", (e) => {
                  if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
                    e.preventDefault()
                    this.pushEvent("parse_eft", {})
                  }
                })
                ta.addEventListener("dragover", (e) => { e.preventDefault() })
                ta.addEventListener("drop", (e) => {
                  if (!e.dataTransfer || !e.dataTransfer.files || !e.dataTransfer.files.length) return
                  e.preventDefault()
                  const file = e.dataTransfer.files[0]
                  const reader = new FileReader()
                  reader.onload = () => {
                    ta.value = reader.result
                    ta.dispatchEvent(new Event("input", { bubbles: true }))
                  }
                  reader.readAsText(file)
                })
              }
            }
          </script>
        </div>
      </div>
    <% end %>
    """
  end

  defp eft_placeholder do
    """
    [Astero, Cap-Stable Tank]

    Damage Control II
    Small Armor Repairer II
    [Empty Low slot]

    1MN Afterburner II
    [Empty Med slot]

    Light Neutron Blaster II
    [Empty High slot]
    """
  end

  defp count_abyssal_slots(%{low_slots: l, med_slots: m, high_slots: h, rig_slots: r}) do
    Enum.count(List.flatten([l, m, h, r]), &(&1 != nil))
  end

  defp count_abyssal_slots(_), do: 0

  defp pluralize(1, s, _), do: s
  defp pluralize(_, _, p), do: p

  # ── Sidebar ────────────────────────────────────────────────────────

  attr :fitting, :any, required: true
  attr :constraints, :map, required: true
  attr :criteria, :any, required: true
  attr :solver_mode, :atom, required: true
  attr :included_type_ids, :list, required: true
  attr :module_types, :list, required: true
  attr :types_popover_open, :boolean, required: true
  attr :type_filter, :string, required: true

  defp tune_sidebar(assigns) do
    disabled = is_nil(assigns.fitting)
    assigns = assign(assigns, :disabled, disabled)

    ~H"""
    <aside
      class={[
        "panel self-start lg:sticky lg:top-[72px] max-h-[calc(100vh-72px)] overflow-y-auto",
        @disabled && "opacity-60 pointer-events-none"
      ]}
      aria-disabled={@disabled}
    >
      <div class="panel-header">
        <h2 class="text-[13px] font-semibold uppercase tracking-wider text-ink-3">Tune</h2>
        <span class="text-[11px] text-ink-4 tnum">
          {if @fitting, do: "ready", else: "load a fit"}
        </span>
      </div>

      <div class="panel-body space-y-5">
        <section>
          <h3 class="field-label mb-2">Constraints</h3>
          <form phx-change="update_constraints" phx-debounce="300" class="space-y-2">
            <.constraint_field
              label="CPU"
              unit="tf"
              name="cpu_capacity"
              value={@constraints.cpu_capacity}
            />
            <.constraint_field
              label="Power grid"
              unit="MW"
              name="power_capacity"
              value={@constraints.power_capacity}
            />
            <.constraint_field
              label="Calibration"
              unit=""
              name="calibration_capacity"
              value={@constraints.calibration_capacity}
            />
            <div class="grid grid-cols-[1fr_auto] items-center gap-2 pt-1">
              <span class="text-[12px] text-ink-3">Max budget (ISK)</span>
              <input
                type="number"
                name="max_price"
                class="input input-sm tnum w-32 text-right"
                placeholder="No limit"
                value={@constraints.max_price}
              />
            </div>
          </form>
        </section>

        <section>
          <h3 class="field-label mb-2">Slots</h3>
          <form phx-change="update_constraints" phx-debounce="300" class="grid grid-cols-4 gap-2">
            <.slot_field name="high_slots" label="H" value={@constraints.available_slots.high} />
            <.slot_field name="med_slots" label="M" value={@constraints.available_slots.med} />
            <.slot_field name="low_slots" label="L" value={@constraints.available_slots.low} />
            <.slot_field name="rig_slots" label="R" value={@constraints.available_slots.rig} />
            <input type="hidden" name="cpu_capacity" value={@constraints.cpu_capacity} />
            <input type="hidden" name="power_capacity" value={@constraints.power_capacity} />
            <input
              type="hidden"
              name="calibration_capacity"
              value={@constraints.calibration_capacity}
            />
            <input type="hidden" name="max_price" value={@constraints.max_price} />
          </form>
        </section>

        <section>
          <h3 class="field-label mb-2">Objectives</h3>
          <div class="space-y-2.5">
            <%= for {key, label} <- objective_rows() do %>
              <.objective_slider
                key={key}
                label={label}
                value={objective_weight(@criteria, key)}
              />
            <% end %>
          </div>
        </section>

        <details class="group">
          <summary class="flex items-baseline justify-between cursor-pointer list-none mb-2 select-none">
            <span class="field-label mb-0 flex items-center gap-1.5">
              <span
                class="text-ink-4 text-[10px] transition-transform group-open:rotate-90"
                aria-hidden="true"
              >
                ▸
              </span>
              Solver
            </span>
            <span class="text-[11px] text-ink-4 capitalize">{@solver_mode}</span>
          </summary>
          <div class="grid grid-cols-2 gap-1">
            <.solver_radio
              mode="heuristic"
              current={@solver_mode}
              label="Heuristic"
              hint="under 1s"
            />
            <.solver_radio
              mode="constraint"
              current={@solver_mode}
              label="Constraint"
              hint="up to 30s"
            />
          </div>
          <p class="mt-1.5 text-[11px] text-ink-4 leading-snug">
            {if @solver_mode == :heuristic,
              do: "Picks first viable fit.",
              else: "Searches all combinations."}
          </p>
        </details>

        <details class="group relative">
          <summary class="flex items-baseline justify-between cursor-pointer list-none mb-2 select-none">
            <span class="field-label mb-0 flex items-center gap-1.5">
              <span
                class="text-ink-4 text-[10px] transition-transform group-open:rotate-90"
                aria-hidden="true"
              >
                ▸
              </span>
              Module types
            </span>
            <span class="text-[11px] text-ink-4 tnum">
              {length(@included_type_ids)} included
            </span>
          </summary>
          <p class="text-[11px] text-ink-4 leading-snug">
            Included types match your fit's slots.
            <button
              type="button"
              phx-click="toggle_types_popover"
              class="text-ink-2 hover:text-ink-1 underline underline-offset-2 ml-1"
            >
              Edit included
            </button>
          </p>

          <%= if @types_popover_open do %>
            <.types_popover
              module_types={@module_types}
              included_type_ids={@included_type_ids}
              type_filter={@type_filter}
            />
          <% end %>
        </details>
      </div>
    </aside>
    """
  end

  attr :label, :string, required: true
  attr :unit, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, required: true

  defp constraint_field(assigns) do
    ~H"""
    <div class="grid grid-cols-[1fr_auto] items-center gap-2">
      <span class="text-[12px] text-ink-3">
        {@label}<span :if={@unit != ""} class="text-ink-4"> ({@unit})</span>
      </span>
      <input
        type="number"
        name={@name}
        class="input input-sm tnum w-24 text-right"
        value={format_float(@value)}
        step="0.1"
      />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp slot_field(assigns) do
    ~H"""
    <label class="flex flex-col items-center gap-1">
      <span class="text-[10px] uppercase tracking-wider text-ink-3 font-medium">{@label}</span>
      <input
        type="number"
        name={@name}
        class="input input-sm tnum text-center px-0 w-full"
        value={@value}
        min="0"
        max="8"
      />
    </label>
    """
  end

  defp objective_rows do
    [
      {"price", "Price"},
      {"performance", "Performance"},
      {"efficiency", "Efficiency"},
      {"volume", "Availability"}
    ]
  end

  defp objective_weight(criteria, "price"), do: criteria.price_weight || 0.0
  defp objective_weight(criteria, "performance"), do: criteria.performance_weight || 0.0
  defp objective_weight(criteria, "efficiency"), do: criteria.efficiency_weight || 0.0
  defp objective_weight(criteria, "volume"), do: criteria.volume_weight || 0.0
  defp objective_weight(_, _), do: 0.0

  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp objective_slider(assigns) do
    ~H"""
    <form
      phx-change="update_objective"
      phx-debounce="200"
      class="grid grid-cols-[64px_1fr_28px] items-center gap-2"
    >
      <span class="text-[12px] text-ink-3">{@label}</span>
      <input type="hidden" name="key" value={@key} />
      <input
        type="range"
        name="value"
        min="0"
        max="1"
        step="0.05"
        value={@value}
        class="w-full accent-accent"
      />
      <span class="text-[11px] text-ink-2 tnum text-right">
        {format_weight(@value)}
      </span>
    </form>
    """
  end

  defp format_weight(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp format_weight(_), do: "0.50"

  attr :mode, :string, required: true
  attr :current, :atom, required: true
  attr :label, :string, required: true
  attr :hint, :string, required: true

  defp solver_radio(assigns) do
    selected = to_string(assigns.current) == assigns.mode
    assigns = assign(assigns, :selected, selected)

    ~H"""
    <label class={[
      "text-[12px] text-center py-1.5 border rounded-md cursor-pointer transition-colors",
      if(@selected,
        do: "bg-surface-3 text-ink-1 border-rule-strong",
        else: "text-ink-3 border-rule-1 hover:text-ink-1 hover:border-rule-2"
      )
    ]}>
      <input
        type="radio"
        name="mode"
        value={@mode}
        checked={@selected}
        phx-click="update_solver_mode"
        phx-value-mode={@mode}
        class="sr-only"
      />
      <span class="block">{@label}</span>
      <span class="block text-[10px] text-ink-4 mt-0.5">{@hint}</span>
    </label>
    """
  end

  attr :module_types, :list, required: true
  attr :included_type_ids, :list, required: true
  attr :type_filter, :string, required: true

  defp types_popover(assigns) do
    filter = String.downcase(assigns.type_filter || "")

    filtered =
      if filter == "" do
        assigns.module_types
      else
        Enum.filter(assigns.module_types, fn t ->
          String.contains?(String.downcase(t.name), filter)
        end)
      end

    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <div
      id="types-popover"
      class="absolute z-30 mt-2 left-0 right-0 panel"
      style="box-shadow: var(--shadow-popover);"
      phx-click-away="close_types_popover"
      role="dialog"
      aria-label="Edit included module types"
    >
      <div class="panel-header">
        <span class="text-[12px] text-ink-3">
          {length(@included_type_ids)} of {length(@module_types)} included
        </span>
        <button
          type="button"
          phx-click="reset_types_to_fit"
          class="text-[11px] text-ink-2 hover:text-ink-1 underline underline-offset-2"
        >
          Reset to fit
        </button>
      </div>

      <form phx-change="filter_types" class="px-3 py-2 border-b border-rule-1">
        <input
          type="text"
          name="q"
          value={@type_filter}
          phx-debounce="150"
          placeholder="Filter types"
          class="input input-sm"
          autocomplete="off"
        />
      </form>

      <ul class="max-h-72 overflow-y-auto py-1">
        <%= for type <- @filtered do %>
          <% included = type.eve_type_id in @included_type_ids %>
          <li>
            <button
              type="button"
              phx-click="toggle_module_type"
              phx-value-type_id={type.eve_type_id}
              class={[
                "w-full flex items-center gap-3 px-3 py-1.5 text-left transition-colors",
                included && "bg-surface-2"
              ]}
            >
              <span
                class={[
                  "w-3.5 h-3.5 rounded-sm border inline-flex items-center justify-center text-[10px]",
                  included && "bg-accent border-accent text-accent-ink",
                  !included && "border-rule-2"
                ]}
                aria-hidden="true"
              >
                {if included, do: "✓", else: ""}
              </span>
              <span class="text-[13px] text-ink-1 truncate flex-1">{type.name}</span>
              <span class="text-[11px] text-ink-4 truncate">{type.category}</span>
            </button>
          </li>
        <% end %>
        <li :if={@filtered == []} class="px-3 py-4 text-[12px] text-ink-4 text-center">
          No types match.
        </li>
      </ul>
    </div>
    """
  end

  # ── Runbar ─────────────────────────────────────────────────────────

  attr :fitting, :any, required: true
  attr :included_type_ids, :list, required: true
  attr :solver_mode, :atom, required: true
  attr :optimizing, :boolean, required: true
  attr :loading_modules, :boolean, required: true
  attr :optimization_elapsed, :integer, required: true
  attr :optimization_error, :any, required: true

  defp runbar(assigns) do
    ~H"""
    <div class="panel">
      <div class="px-5 py-3 flex items-center gap-3 flex-wrap">
        <%= if @optimizing do %>
          <button type="button" class="btn btn-sm btn-danger" phx-click="cancel_optimize">
            Cancel
          </button>
          <span class="text-[12px] text-ink-3 animate-skeleton-pulse">
            {if @loading_modules,
              do: "Loading candidates",
              else: "Optimizing"}
          </span>
          <span class="text-[12px] text-ink-3">·</span>
          <span class="text-[12px] text-ink-2 capitalize">{@solver_mode}</span>
          <span class="text-[12px] text-ink-3">·</span>
          <span class="text-[12px] text-ink-1 tnum">{format_elapsed(@optimization_elapsed)}</span>
        <% else %>
          <button
            type="button"
            class="btn btn-primary"
            phx-click="optimize"
            disabled={is_nil(@fitting) or Enum.empty?(@included_type_ids)}
          >
            Optimize
          </button>
          <span class="text-[12px] text-ink-3">·</span>
          <span class="text-[12px] text-ink-2 capitalize">{@solver_mode}</span>
          <span class="text-[12px] text-ink-3">·</span>
          <span class="text-[12px] text-ink-3 tnum">
            {length(@included_type_ids)} {pluralize(length(@included_type_ids), "type", "types")}
          </span>
          <span class="hidden md:inline text-[12px] text-ink-3 md:ml-auto whitespace-nowrap">
            Ctrl-Enter to run
          </span>
        <% end %>
      </div>

      <div :if={@optimization_error} class="px-5 py-3 border-t border-rule-1 flex items-start gap-2">
        <span class="text-status-error mt-0.5" aria-hidden="true">!</span>
        <div class="flex-1">
          <p class="text-ink-1 text-[13px]">Optimization failed</p>
          <p class="text-ink-3 text-[12px] mt-0.5">{@optimization_error}</p>
        </div>
        <button type="button" class="btn btn-sm" phx-click="optimize">Retry</button>
      </div>
    </div>
    """
  end

  defp format_elapsed(0), do: "0.0s"

  defp format_elapsed(ms) when is_integer(ms) do
    seconds = ms / 1000

    cond do
      seconds < 60 ->
        :erlang.float_to_binary(seconds, decimals: 1) <> "s"

      true ->
        m = div(ms, 60_000)
        s = rem(ms, 60_000) / 1000
        "#{m}m #{:erlang.float_to_binary(s, decimals: 1)}s"
    end
  end

  # ── Solutions panel ───────────────────────────────────────────────

  attr :fitting, :any, required: true
  attr :solutions, :list, required: true
  attr :selected_solution, :any, required: true
  attr :optimizing, :boolean, required: true
  attr :constraints, :map, required: true
  attr :copy_state, :atom, required: true
  attr :expanded_module_id, :any, required: true

  defp solutions_panel(assigns) do
    ~H"""
    <%= cond do %>
      <% is_nil(@fitting) -> %>
        <div class="panel">
          <div class="px-6 py-12 text-center">
            <p class="text-ink-1 text-[15px]">Load a fitting to begin.</p>
            <p class="text-ink-3 text-[13px] mt-1">
              Paste an EFT above. The optimizer will fill the abyssal slots.
            </p>
          </div>
        </div>
      <% Enum.empty?(@solutions) and @optimizing -> %>
        <.solutions_skeleton />
      <% Enum.empty?(@solutions) -> %>
        <div class="panel">
          <div class="px-6 py-12 text-center">
            <p class="text-ink-1 text-[15px]">No run yet.</p>
            <p class="text-ink-3 text-[13px] mt-1">
              Press Optimize, or Ctrl-Enter, to fill the slots.
            </p>
          </div>
        </div>
      <% true -> %>
        <div class={["space-y-4", @optimizing && "opacity-50"]} aria-busy={@optimizing}>
          <.solutions_table
            solutions={@solutions}
            selected_solution={@selected_solution}
            fitting={@fitting}
          />
          <.selected_detail
            solution={@selected_solution}
            constraints={@constraints}
            fitting={@fitting}
            copy_state={@copy_state}
            expanded_module_id={@expanded_module_id}
          />
        </div>
    <% end %>
    """
  end

  defp solutions_skeleton(assigns) do
    ~H"""
    <div class="panel overflow-hidden">
      <table class="dense">
        <thead>
          <tr>
            <th class="w-6"></th>
            <th>#</th>
            <th class="text-right">Score</th>
            <th class="text-right">Cost (ISK)</th>
          </tr>
        </thead>
        <tbody class="animate-skeleton-pulse">
          <%= for _ <- 1..3 do %>
            <tr>
              <td></td>
              <td><span class="block h-3 w-6 bg-surface-2 rounded" /></td>
              <td class="text-right">
                <span class="block h-3 w-12 bg-surface-2 rounded ml-auto" />
              </td>
              <td class="text-right">
                <span class="block h-3 w-20 bg-surface-2 rounded ml-auto" />
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :solutions, :list, required: true
  attr :selected_solution, :any, required: true
  attr :fitting, :any, required: true

  defp solutions_table(assigns) do
    ~H"""
    <div class="panel overflow-hidden">
      <table class="dense" id="solutions-table" phx-hook=".SolutionsKeyNav" tabindex="0">
        <thead>
          <tr>
            <th class="w-6" aria-hidden="true"></th>
            <th class="w-12">#</th>
            <th class="text-right">Score</th>
            <th class="text-right">Cost (ISK)</th>
          </tr>
        </thead>
        <tbody>
          <%= for {solution, idx} <- Enum.with_index(@solutions) do %>
            <% is_top = idx == 0
            is_selected = @selected_solution && @selected_solution.id == solution.id %>
            <tr
              id={"solution-#{idx}"}
              phx-click="select_solution"
              phx-value-index={idx}
              data-index={idx}
              class={[
                "cursor-pointer",
                is_selected && "is-selected"
              ]}
            >
              <td class="text-center text-ink-3 text-[11px]" aria-hidden="true">
                {if is_top, do: "●", else: ""}
              </td>
              <td class="text-ink-2 tnum">{solution.rank || idx + 1}</td>
              <td class="text-right">
                <span class="tnum text-ink-1">{format_score(solution.total_score)}</span>
              </td>
              <td class="text-right tnum">{format_price_plain(solution.total_price)}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SolutionsKeyNav">
        export default {
          mounted() {
            this.idx = 0
            this.handler = (e) => {
              if (e.target.matches("input, textarea, [contenteditable]")) return
              const rows = this.el.querySelectorAll("tbody tr[data-index]")
              if (rows.length === 0) return
              let next = null
              if (e.key === "j" || e.key === "ArrowDown") next = Math.min(this.idx + 1, rows.length - 1)
              else if (e.key === "k" || e.key === "ArrowUp") next = Math.max(this.idx - 1, 0)
              else return
              e.preventDefault()
              this.idx = next
              const row = rows[next]
              this.pushEvent("select_solution", { index: String(next) })
              row.scrollIntoView({ block: "nearest" })
            }
            window.addEventListener("keydown", this.handler)
          },
          destroyed() {
            window.removeEventListener("keydown", this.handler)
          }
        }
      </script>
    </div>
    """
  end

  attr :solution, :any, required: true
  attr :constraints, :map, required: true
  attr :fitting, :any, required: true
  attr :copy_state, :atom, required: true
  attr :expanded_module_id, :any, required: true

  defp selected_detail(assigns) do
    ~H"""
    <%= if @solution do %>
      <div class="panel">
        <div class="panel-header">
          <div class="flex items-baseline gap-3">
            <span class="text-[11px] uppercase tracking-wider text-ink-3 font-medium">
              Selected
            </span>
            <span class="text-ink-1 tnum">#{@solution.rank}</span>
            <span class="text-ink-3 text-[12px]">·</span>
            <span class="text-ink-2 text-[12px]">
              {length(@solution.modules)} modules
            </span>
          </div>
          <div class="flex items-center gap-2">
            <button
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="export_eft"
            >
              {if @copy_state == :eft, do: "Copied", else: "Copy as EFT"}
            </button>
            <button
              type="button"
              class="btn btn-sm"
              phx-click="export_json"
            >
              {if @copy_state == :json, do: "Copied", else: "Copy as JSON"}
            </button>
            <button type="button" class="btn btn-sm btn-ghost" phx-click="export_all_json">
              Save all (JSON)
            </button>
          </div>
        </div>

        <div class="panel-body">
          <.resource_meters solution={@solution} constraints={@constraints} />
        </div>

        <ul class="divide-y divide-rule-1 border-t border-rule-1">
          <%= for {label, atom} <- [{"High", :high}, {"Med", :med}, {"Low", :low}, {"Rig", :rig}] do %>
            <% modules = Enum.filter(@solution.modules, &(&1.slot_type == atom)) %>
            <%= if modules != [] do %>
              <li class="px-5 py-1.5 bg-surface-2/40">
                <span class="text-[10px] uppercase tracking-wider text-ink-3 font-semibold">
                  {label} ({length(modules)})
                </span>
              </li>
            <% end %>
            <%= for {mod, slot_idx} <- Enum.with_index(modules, 1) do %>
              <% is_expanded = @expanded_module_id == mod.id %>
              <li>
                <button
                  type="button"
                  class="w-full px-5 py-2.5 flex items-baseline gap-4 text-left hover:bg-surface-2 transition-colors"
                  phx-click="toggle_module_detail"
                  phx-value-module-id={mod.id}
                  aria-expanded={to_string(is_expanded)}
                >
                  <span class="text-[11px] uppercase tracking-wider text-ink-3 font-medium w-14 shrink-0">
                    {label} {slot_idx}
                  </span>
                  <.icon
                    name={if is_expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
                    class="size-3 text-ink-3 shrink-0"
                  />
                  <span class="text-ink-1 text-[13px] flex-1 min-w-0 truncate">
                    {mod.name}
                  </span>
                  <span class="text-ink-2 text-[12px] tnum">
                    {format_score(mod.score)}
                  </span>
                  <span class="text-ink-3 text-[12px] tnum w-32 text-right">
                    {format_price_plain(mod.price)} ISK
                  </span>
                </button>
                <%= if is_expanded do %>
                  <div class="px-5 pb-3 pl-[5.5rem] bg-surface-2">
                    <.module_detail mod={mod} />
                  </div>
                <% end %>
              </li>
            <% end %>
          <% end %>
        </ul>
      </div>
    <% else %>
      <div class="panel">
        <div class="px-6 py-8 text-center text-ink-3 text-[13px]">
          Select a solution above.
        </div>
      </div>
    <% end %>
    """
  end

  attr :mod, :any, required: true

  defp module_detail(assigns) do
    ~H"""
    <div class="pt-2 space-y-2 text-[12px]">
      <div class="flex items-center gap-3">
        <%= if @mod.external_id && @mod.external_id != "" do %>
          <a
            href={"https://mutamarket.com/modules/#{@mod.external_id}"}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex items-center gap-1 text-accent hover:underline"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-3" /> View on Mutamarket
          </a>
        <% end %>
        <span class="text-ink-3 font-mono">id: {@mod.external_id}</span>
      </div>
      <%= if @mod.attributes && map_size(@mod.attributes) > 0 do %>
        <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1">
          <%= for {key, attr} <- Enum.sort(@mod.attributes) do %>
            <div class="flex items-baseline justify-between gap-2 border-b border-rule-1/40 py-1">
              <dt class="text-ink-3 truncate">{key}</dt>
              <dd class="text-ink-1 tnum text-right">
                {format_attr_value(attr)}
                <%= if attr_unit(attr) do %>
                  <span class="text-ink-3 ml-1">{attr_unit(attr)}</span>
                <% end %>
              </dd>
            </div>
          <% end %>
        </dl>
      <% end %>
    </div>
    """
  end

  defp format_attr_value(%{"value" => v}), do: format_float(v)
  defp format_attr_value(v) when is_number(v), do: format_float(v)
  defp format_attr_value(v), do: to_string(v)

  defp attr_unit(%{"unit" => u}) when is_binary(u) and u != "", do: u
  defp attr_unit(_), do: nil

  attr :solution, :any, required: true
  attr :constraints, :map, required: true

  defp resource_meters(assigns) do
    ~H"""
    <div class="grid grid-cols-3 gap-4">
      <.resource_meter
        label="CPU"
        unit="tf"
        used={@solution.resource_usage.cpu}
        cap={@constraints.cpu_capacity}
      />
      <.resource_meter
        label="Power grid"
        unit="MW"
        used={@solution.resource_usage.power}
        cap={@constraints.power_capacity}
      />
      <.resource_meter
        label="Calibration"
        unit=""
        used={@solution.resource_usage.calibration}
        cap={@constraints.calibration_capacity}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :unit, :string, required: true
  attr :used, :any, required: true
  attr :cap, :any, required: true

  defp resource_meter(assigns) do
    pct =
      cond do
        is_nil(assigns.cap) or assigns.cap == 0 -> 0.0
        true -> min(assigns.used / assigns.cap, 1.0)
      end

    over = assigns.used > assigns.cap
    assigns = assign(assigns, :pct, pct) |> assign(:over, over)

    ~H"""
    <div>
      <div class="flex items-baseline justify-between gap-2">
        <span class="text-[11px] uppercase tracking-wider text-ink-3 font-medium">
          {@label}
        </span>
        <span class="flex items-baseline gap-1.5">
          <span
            :if={@over}
            class="text-[10px] uppercase tracking-wider text-ink-3 font-medium"
            aria-label="over capacity"
          >
            ! Over
          </span>
          <span class={["text-[12px] tnum", @over && "text-status-error"]}>
            {format_meter(@used, @cap)}{if @unit != "", do: " " <> @unit}
          </span>
        </span>
      </div>
      <span class="block mt-1.5 h-1 w-full bg-surface-3 rounded-sm overflow-hidden">
        <span
          class={["block h-full", @over && "bg-status-error", !@over && "bg-accent"]}
          style={"width: #{round(@pct * 100)}%"}
        />
      </span>
    </div>
    """
  end

  defp format_meter(used, cap) when is_number(used) and is_number(cap) do
    "#{:erlang.float_to_binary(used * 1.0, decimals: 1)} / #{:erlang.float_to_binary(cap * 1.0, decimals: 0)}"
  end

  defp format_meter(used, _) when is_number(used),
    do: :erlang.float_to_binary(used * 1.0, decimals: 1)

  defp format_meter(_, _), do: "n/a"

  defp format_score(score) when is_number(score),
    do: :erlang.float_to_binary(score * 1.0, decimals: 2)

  defp format_score(_), do: "n/a"

  defp format_float(value) when is_float(value) do
    if value == Float.round(value, 0) do
      Integer.to_string(trunc(value))
    else
      :erlang.float_to_binary(value, decimals: 1)
    end
  end

  defp format_float(value) when is_integer(value), do: Integer.to_string(value)
  defp format_float(value), do: to_string(value)

  defp format_price_plain(nil), do: "n/a"

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

  defp format_price_plain(_), do: "n/a"
end
