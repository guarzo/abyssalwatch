defmodule AbyssalwatchWeb.OptimizationLive do
  @moduledoc """
  LiveView for the ship fitting optimization wizard.

  Provides a multi-step workflow:
  1. Import - Load fitting via EFT paste or file upload
  2. Constraints - Configure CPU, power grid, calibration limits
  3. Objectives - Set module selection criteria and scoring weights
  4. Optimize - Run the solver and display progress
  5. Results - Review and export solutions
  """

  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Fittings.Parsers.EFT
  alias Abyssalwatch.Optimization
  alias Abyssalwatch.Optimization.Types.Constraints
  alias Abyssalwatch.Market.ModuleType
  alias Abyssalwatch.Market.Scoring.{Topsis, Criteria}
  alias Abyssalwatch.Market.Mutamarket.Client, as: MutamarketClient

  @steps [:import, :constraints, :objectives, :optimize, :results]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:step, :import)
     |> assign(:steps, @steps)
     |> assign(:fitting, nil)
     |> assign(:constraints, default_constraints())
     |> assign(:criteria, Criteria.default())
     |> assign(:solver_mode, :heuristic)
     |> assign(:selected_types, [])
     |> assign(:module_types, load_module_types())
     |> assign(:candidates, [])
     |> assign(:solutions, [])
     |> assign(:selected_solution, nil)
     |> assign(:optimizing, false)
     |> assign(:optimization_error, nil)
     |> assign(:eft_input, "")
     |> assign(:loading_modules, false)
     |> assign(:optimization_start_time, nil)
     |> assign(:optimization_elapsed, 0)
     |> assign(:optimization_status, "")
     |> allow_upload(:eft_file,
       accept: ~w(.txt .eft),
       max_entries: 1,
       max_file_size: 100_000
     )}
  end

  @impl true
  def handle_event("set_step", %{"step" => step}, socket) do
    step_atom = String.to_existing_atom(step)

    if step_atom in @steps do
      {:noreply, assign(socket, :step, step_atom)}
    else
      {:noreply, socket}
    end
  end

  # Step 1: Import

  @impl true
  def handle_event("update_eft_input", %{"eft" => eft_text}, socket) do
    {:noreply, assign(socket, :eft_input, eft_text)}
  end

  @impl true
  def handle_event("parse_eft", _params, socket) do
    case EFT.parse(socket.assigns.eft_input) do
      {:ok, fitting} ->
        {:noreply,
         socket
         |> assign(:fitting, fitting)
         |> assign(:step, :constraints)
         |> put_flash(:info, "Fitting imported: #{fitting.name}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Parse error: #{reason}")}
    end
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_eft", _params, socket) do
    uploaded_content =
      consume_uploaded_entries(socket, :eft_file, fn %{path: path}, _entry ->
        content = File.read!(path)
        {:ok, content}
      end)

    case uploaded_content do
      [content] ->
        case EFT.parse(content) do
          {:ok, fitting} ->
            {:noreply,
             socket
             |> assign(:fitting, fitting)
             |> assign(:eft_input, content)
             |> assign(:step, :constraints)
             |> put_flash(:info, "Fitting imported from file: #{fitting.name}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Parse error: #{reason}")}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "No file selected")}
    end
  end

  @impl true
  def handle_event("clear_fitting", _params, socket) do
    {:noreply,
     socket
     |> assign(:fitting, nil)
     |> assign(:eft_input, "")
     |> assign(:step, :import)}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :eft_file, ref)}
  end

  # Step 2: Constraints

  @impl true
  def handle_event("update_constraints", params, socket) do
    constraints = %Constraints{
      cpu_capacity: parse_float(params["cpu_capacity"], 0.0),
      power_capacity: parse_float(params["power_capacity"], 0.0),
      calibration_capacity: parse_float(params["calibration_capacity"], 400.0),
      available_slots: %{
        high: parse_int(params["high_slots"], 0),
        med: parse_int(params["med_slots"], 0),
        low: parse_int(params["low_slots"], 0),
        rig: parse_int(params["rig_slots"], 3)
      },
      max_price: parse_decimal(params["max_price"])
    }

    {:noreply, assign(socket, :constraints, constraints)}
  end

  @impl true
  def handle_event("next_from_constraints", _params, socket) do
    case Constraints.validate(socket.assigns.constraints) do
      :ok ->
        {:noreply, assign(socket, :step, :objectives)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  # Step 3: Objectives

  @impl true
  def handle_event("toggle_module_type", %{"type_id" => type_id_str}, socket) do
    type_id = String.to_integer(type_id_str)
    selected = socket.assigns.selected_types

    new_selected =
      if type_id in selected do
        List.delete(selected, type_id)
      else
        [type_id | selected]
      end

    {:noreply, assign(socket, :selected_types, new_selected)}
  end

  @impl true
  def handle_event("update_solver_mode", %{"mode" => mode}, socket) do
    mode_atom =
      case mode do
        "heuristic" -> :heuristic
        "constraint" -> :constraint
        _ -> :heuristic
      end

    {:noreply, assign(socket, :solver_mode, mode_atom)}
  end

  @impl true
  def handle_event("fetch_candidates", _params, socket) do
    if Enum.empty?(socket.assigns.selected_types) do
      {:noreply, put_flash(socket, :error, "Please select at least one module type")}
    else
      socket = assign(socket, :loading_modules, true)
      send(self(), :load_candidates)
      {:noreply, socket}
    end
  end

  # Step 4: Optimize

  @impl true
  def handle_event("run_optimization", _params, socket) do
    if Enum.empty?(socket.assigns.candidates) do
      {:noreply, put_flash(socket, :error, "No module candidates loaded")}
    else
      # Start timer for progress updates
      :timer.send_interval(100, self(), :optimization_tick)

      socket =
        socket
        |> assign(:optimizing, true)
        |> assign(:optimization_start_time, System.monotonic_time(:millisecond))
        |> assign(:optimization_elapsed, 0)
        |> assign(:optimization_status, "Initializing solver...")

      send(self(), :run_optimization)
      {:noreply, socket}
    end
  end

  # Step 5: Results

  @impl true
  def handle_event("select_solution", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    solution = Enum.at(socket.assigns.solutions, index)
    {:noreply, assign(socket, :selected_solution, solution)}
  end

  @impl true
  def handle_event("export_eft", _params, socket) do
    case socket.assigns.selected_solution do
      nil ->
        {:noreply, put_flash(socket, :error, "No solution selected")}

      solution ->
        ship_name = socket.assigns.fitting.ship_type
        fit_name = "#{socket.assigns.fitting.name} (Optimized)"
        eft = Optimization.export_to_eft(solution, ship_name, fit_name)
        {:noreply, push_event(socket, "copy_to_clipboard", %{text: eft})}
    end
  end

  @impl true
  def handle_event("export_json", _params, socket) do
    case socket.assigns.selected_solution do
      nil ->
        {:noreply, put_flash(socket, :error, "No solution selected")}

      solution ->
        json_data = Optimization.export_to_json(solution)
        json_string = Jason.encode!(json_data, pretty: true)
        {:noreply, push_event(socket, "copy_to_clipboard", %{text: json_string})}
    end
  end

  @impl true
  def handle_event("export_all_json", _params, socket) do
    if Enum.empty?(socket.assigns.solutions) do
      {:noreply, put_flash(socket, :error, "No solutions to export")}
    else
      ship_name = socket.assigns.fitting.ship_type
      fit_name = "#{socket.assigns.fitting.name} (Optimized)"

      json_data =
        Optimization.export_solutions_to_json(
          socket.assigns.solutions,
          ship_name,
          fit_name
        )

      json_string = Jason.encode!(json_data, pretty: true)

      {:noreply,
       push_event(socket, "download_file", %{
         content: json_string,
         filename: "#{fit_name}.json",
         type: "application/json"
       })}
    end
  end

  @impl true
  def handle_event("start_over", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :import)
     |> assign(:fitting, nil)
     |> assign(:eft_input, "")
     |> assign(:candidates, [])
     |> assign(:solutions, [])
     |> assign(:selected_solution, nil)
     |> assign(:selected_types, [])}
  end

  # Async handlers

  @impl true
  def handle_info(:load_candidates, socket) do
    candidates =
      socket.assigns.selected_types
      |> Enum.flat_map(fn type_id ->
        type = Enum.find(socket.assigns.module_types, &(&1.eve_type_id == type_id))
        slot_type = get_slot_type(type)

        case MutamarketClient.search_modules(type_id) do
          {:ok, modules} ->
            criteria = Criteria.merge_with_module_type(socket.assigns.criteria, type)
            scored = Topsis.score(modules, criteria)
            Optimization.prepare_candidates(scored, slot_type)

          {:error, _} ->
            []
        end
      end)

    {:noreply,
     socket
     |> assign(:candidates, candidates)
     |> assign(:loading_modules, false)
     |> assign(:step, :optimize)
     |> put_flash(:info, "Loaded #{length(candidates)} candidate modules")}
  end

  @impl true
  def handle_info(:run_optimization, socket) do
    # Update status
    socket =
      assign(socket, :optimization_status, "Running #{socket.assigns.solver_mode} solver...")

    result =
      Optimization.optimize(
        socket.assigns.candidates,
        socket.assigns.constraints,
        mode: socket.assigns.solver_mode
      )

    case result do
      {:ok, %{solutions: solutions, solve_time_ms: solve_time}} ->
        {:noreply,
         socket
         |> assign(:solutions, solutions)
         |> assign(:selected_solution, List.first(solutions))
         |> assign(:optimizing, false)
         |> assign(:optimization_status, "")
         |> assign(:step, :results)
         |> put_flash(:info, "Found #{length(solutions)} solutions in #{solve_time}ms")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:optimization_error, reason)
         |> assign(:optimizing, false)
         |> assign(:optimization_status, "")
         |> put_flash(:error, "Optimization failed: #{reason}")}
    end
  end

  @impl true
  def handle_info(:optimization_tick, socket) do
    if socket.assigns.optimizing do
      elapsed = System.monotonic_time(:millisecond) - socket.assigns.optimization_start_time

      status =
        cond do
          elapsed < 500 -> "Initializing solver..."
          elapsed < 2000 -> "Exploring solution space..."
          elapsed < 5000 -> "Evaluating candidates..."
          elapsed < 10000 -> "Finding optimal configurations..."
          true -> "Deep search in progress..."
        end

      {:noreply,
       socket
       |> assign(:optimization_elapsed, elapsed)
       |> assign(:optimization_status, status)}
    else
      {:noreply, socket}
    end
  end

  # Helpers

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

  defp get_slot_type(nil), do: :low
  defp get_slot_type(%{slot_type: "high"}), do: :high
  defp get_slot_type(%{slot_type: "med"}), do: :med
  defp get_slot_type(%{slot_type: "low"}), do: :low
  defp get_slot_type(%{slot_type: "rig"}), do: :rig

  defp get_slot_type(%{category: category}) do
    cond do
      String.contains?(String.downcase(category || ""), "propulsion") -> :med
      String.contains?(String.downcase(category || ""), "shield") -> :med
      String.contains?(String.downcase(category || ""), "armor") -> :low
      String.contains?(String.downcase(category || ""), "damage") -> :low
      true -> :low
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(value, _default) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp parse_float(value, _) when is_number(value), do: value / 1.0
  defp parse_float(_, default), do: default

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_int(value, _) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(_), do: nil

  defp step_index(step), do: Enum.find_index(@steps, &(&1 == step)) || 0

  defp step_complete?(step, current_step) do
    step_index(step) < step_index(current_step)
  end

  defp step_current?(step, current_step), do: step == current_step

  # Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-6xl">
      <h1 class="text-3xl font-bold mb-8">Ship Fitting Optimization</h1>
      
    <!-- Progress Steps -->
      <ul class="steps steps-horizontal w-full mb-8">
        <%= for step <- @steps do %>
          <li class={"step #{if step_complete?(step, @step), do: "step-primary"} #{if step_current?(step, @step), do: "step-primary font-bold"}"}>
            {step_label(step)}
          </li>
        <% end %>
      </ul>
      
    <!-- Step Content -->
      <div class="bg-base-200 rounded-lg p-6">
        <%= case @step do %>
          <% :import -> %>
            <.import_step {assigns} />
          <% :constraints -> %>
            <.constraints_step {assigns} />
          <% :objectives -> %>
            <.objectives_step {assigns} />
          <% :optimize -> %>
            <.optimize_step {assigns} />
          <% :results -> %>
            <.results_step {assigns} />
        <% end %>
      </div>
    </div>
    """
  end

  defp import_step(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Import Fitting</h2>
      <p class="text-gray-500 mb-4">
        Import your ship fitting in EFT format. You can paste it directly or upload a file.
      </p>

      <%= if @fitting do %>
        <div class="alert alert-success mb-4">
          <span>Loaded: <strong>{@fitting.ship_type}</strong> - {@fitting.name}</span>
          <button class="btn btn-ghost btn-sm" phx-click="clear_fitting">Clear</button>
        </div>
      <% else %>
        <div class="tabs tabs-boxed mb-4">
          <button
            class="tab tab-active"
            id="paste-tab"
            onclick="document.getElementById('paste-panel').classList.remove('hidden'); document.getElementById('upload-panel').classList.add('hidden'); this.classList.add('tab-active'); document.getElementById('upload-tab').classList.remove('tab-active');"
          >
            Paste EFT
          </button>
          <button
            class="tab"
            id="upload-tab"
            onclick="document.getElementById('upload-panel').classList.remove('hidden'); document.getElementById('paste-panel').classList.add('hidden'); this.classList.add('tab-active'); document.getElementById('paste-tab').classList.remove('tab-active');"
          >
            Upload File
          </button>
        </div>
        
    <!-- Paste Panel -->
        <div id="paste-panel">
          <div class="form-control">
            <textarea
              class="textarea textarea-bordered h-64 font-mono text-sm"
              placeholder="[Ship Type, Fitting Name]&#10;&#10;Damage Control II&#10;Armor Plates&#10;&#10;10MN Afterburner II&#10;Warp Scrambler II&#10;&#10;..."
              phx-change="update_eft_input"
              name="eft"
            ><%= @eft_input %></textarea>
          </div>

          <div class="mt-4">
            <button
              class="btn btn-primary"
              phx-click="parse_eft"
              disabled={String.trim(@eft_input) == ""}
            >
              Parse Fitting
            </button>
          </div>
        </div>
        
    <!-- Upload Panel -->
        <div id="upload-panel" class="hidden">
          <form id="upload-form" phx-submit="upload_eft" phx-change="validate_upload">
            <div class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center">
              <.live_file_input
                upload={@uploads.eft_file}
                class="file-input file-input-bordered w-full max-w-xs"
              />
              <p class="mt-2 text-sm text-gray-500">
                Upload a .txt or .eft file containing your fitting in EFT format
              </p>

              <%= for entry <- @uploads.eft_file.entries do %>
                <div class="mt-4 flex items-center justify-center gap-2">
                  <span class="text-sm">{entry.client_name}</span>
                  <progress class="progress progress-primary w-24" value={entry.progress} max="100">
                  </progress>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="cancel-upload"
                    phx-value-ref={entry.ref}
                  >
                    ✕
                  </button>
                </div>

                <%= for err <- upload_errors(@uploads.eft_file, entry) do %>
                  <p class="text-error text-sm mt-1">{error_to_string(err)}</p>
                <% end %>
              <% end %>
            </div>

            <div class="mt-4">
              <button
                type="submit"
                class="btn btn-primary"
                disabled={Enum.empty?(@uploads.eft_file.entries)}
              >
                Upload & Parse
              </button>
            </div>
          </form>
        </div>
      <% end %>

      <%= if @fitting do %>
        <div class="mt-6 flex justify-end">
          <button class="btn btn-primary" phx-click="set_step" phx-value-step="constraints">
            Next: Configure Constraints →
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp constraints_step(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Configure Constraints</h2>
      <p class="text-gray-500 mb-4">
        Set your ship's resource limits. These determine which modules can be fitted.
      </p>

      <form phx-change="update_constraints" class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <!-- Resources -->
        <div class="space-y-4">
          <h3 class="font-semibold">Ship Resources</h3>

          <div class="form-control">
            <label class="label"><span class="label-text">CPU Capacity (tf)</span></label>
            <input
              type="number"
              name="cpu_capacity"
              class="input input-bordered"
              value={@constraints.cpu_capacity}
              step="0.1"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Power Grid Capacity (MW)</span></label>
            <input
              type="number"
              name="power_capacity"
              class="input input-bordered"
              value={@constraints.power_capacity}
              step="0.1"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Calibration (points)</span></label>
            <input
              type="number"
              name="calibration_capacity"
              class="input input-bordered"
              value={@constraints.calibration_capacity}
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Max Budget (ISK, optional)</span></label>
            <input
              type="number"
              name="max_price"
              class="input input-bordered"
              placeholder="No limit"
              value={@constraints.max_price}
            />
          </div>
        </div>
        
    <!-- Slots -->
        <div class="space-y-4">
          <h3 class="font-semibold">Available Slots</h3>

          <div class="form-control">
            <label class="label"><span class="label-text">High Slots</span></label>
            <input
              type="number"
              name="high_slots"
              class="input input-bordered"
              value={@constraints.available_slots.high}
              min="0"
              max="8"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Med Slots</span></label>
            <input
              type="number"
              name="med_slots"
              class="input input-bordered"
              value={@constraints.available_slots.med}
              min="0"
              max="8"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Low Slots</span></label>
            <input
              type="number"
              name="low_slots"
              class="input input-bordered"
              value={@constraints.available_slots.low}
              min="0"
              max="8"
            />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Rig Slots</span></label>
            <input
              type="number"
              name="rig_slots"
              class="input input-bordered"
              value={@constraints.available_slots.rig}
              min="0"
              max="3"
            />
          </div>
        </div>
      </form>

      <div class="mt-6 flex justify-between">
        <button class="btn btn-ghost" phx-click="set_step" phx-value-step="import">
          ← Back
        </button>
        <button class="btn btn-primary" phx-click="next_from_constraints">
          Next: Select Module Types →
        </button>
      </div>
    </div>
    """
  end

  defp objectives_step(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Select Module Types</h2>
      <p class="text-gray-500 mb-4">
        Choose which abyssal module types to include in the optimization.
      </p>
      
    <!-- Module Type Selection -->
      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3 mb-6">
        <%= for type <- @module_types do %>
          <label class={"cursor-pointer card bg-base-100 p-3 hover:bg-base-300 transition-colors #{if type.eve_type_id in @selected_types, do: "ring-2 ring-primary"}"}>
            <input
              type="checkbox"
              class="hidden"
              phx-click="toggle_module_type"
              phx-value-type_id={type.eve_type_id}
              checked={type.eve_type_id in @selected_types}
            />
            <div class="flex items-center gap-2">
              <input
                type="checkbox"
                class="checkbox checkbox-primary checkbox-sm"
                checked={type.eve_type_id in @selected_types}
                readonly
              />
              <div>
                <div class="font-medium text-sm">{type.name}</div>
                <div class="text-xs text-gray-500">{type.category}</div>
              </div>
            </div>
          </label>
        <% end %>
      </div>
      
    <!-- Solver Mode -->
      <div class="form-control mb-6">
        <label class="label"><span class="label-text font-semibold">Solver Mode</span></label>
        <select
          class="select select-bordered w-full max-w-xs"
          phx-change="update_solver_mode"
          name="mode"
        >
          <option value="heuristic" selected={@solver_mode == :heuristic}>
            Heuristic (Fast, ~100ms)
          </option>
          <option value="constraint" selected={@solver_mode == :constraint}>
            Constraint (Thorough, ~1-30s)
          </option>
        </select>
        <label class="label">
          <span class="label-text-alt text-gray-500">
            <%= if @solver_mode == :heuristic do %>
              Fast greedy algorithm. Good for exploring options quickly.
            <% else %>
              Branch-and-bound solver. Better for final optimization decisions.
            <% end %>
          </span>
        </label>
      </div>

      <div class="mt-6 flex justify-between">
        <button class="btn btn-ghost" phx-click="set_step" phx-value-step="constraints">
          ← Back
        </button>
        <button
          class="btn btn-primary"
          phx-click="fetch_candidates"
          disabled={Enum.empty?(@selected_types) || @loading_modules}
        >
          <%= if @loading_modules do %>
            <span class="loading loading-spinner loading-sm"></span> Loading Modules...
          <% else %>
            Fetch Modules & Continue →
          <% end %>
        </button>
      </div>
    </div>
    """
  end

  defp optimize_step(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Run Optimization</h2>

      <div class="stats shadow mb-6">
        <div class="stat">
          <div class="stat-title">Candidates</div>
          <div class="stat-value text-primary">{length(@candidates)}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Solver</div>
          <div class="stat-value text-secondary">{@solver_mode}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Slots</div>
          <div class="stat-value">
            {@constraints.available_slots.high + @constraints.available_slots.med +
              @constraints.available_slots.low + @constraints.available_slots.rig}
          </div>
        </div>
      </div>

      <%= if @optimization_error do %>
        <div class="alert alert-error mb-4">
          <span>{@optimization_error}</span>
        </div>
      <% end %>

      <div class="text-center py-8">
        <%= if @optimizing do %>
          <div class="flex flex-col items-center gap-4">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            
    <!-- Progress bar (indeterminate) -->
            <div class="w-64">
              <progress class="progress progress-primary w-full"></progress>
            </div>
            
    <!-- Status message -->
            <p class="text-gray-500 animate-pulse">{@optimization_status}</p>
            
    <!-- Elapsed time -->
            <div class="text-sm text-gray-400">
              Elapsed: <span class="font-mono">{format_elapsed(@optimization_elapsed)}</span>
            </div>
            
    <!-- Solver info -->
            <div class="text-xs text-gray-400 mt-2">
              <%= if @solver_mode == :constraint do %>
                Constraint solver may take up to 30 seconds for complex fittings
              <% else %>
                Heuristic solver is typically fast (&lt; 1 second)
              <% end %>
            </div>
          </div>
        <% else %>
          <button class="btn btn-primary btn-lg" phx-click="run_optimization">
            Run Optimization
          </button>
        <% end %>
      </div>

      <div class="mt-6 flex justify-between">
        <button
          class="btn btn-ghost"
          phx-click="set_step"
          phx-value-step="objectives"
          disabled={@optimizing}
        >
          ← Back
        </button>
      </div>
    </div>
    """
  end

  defp results_step(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Optimization Results</h2>

      <%= if Enum.empty?(@solutions) do %>
        <div class="alert alert-warning">
          <span>
            No solutions found. Try adjusting constraints or selecting different module types.
          </span>
        </div>
      <% else %>
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Solution List -->
          <div class="lg:col-span-1 space-y-2">
            <h3 class="font-semibold mb-2">Solutions ({length(@solutions)})</h3>
            <%= for {solution, idx} <- Enum.with_index(@solutions) do %>
              <div
                class={"card bg-base-100 p-3 cursor-pointer hover:bg-base-300 #{if @selected_solution && @selected_solution.id == solution.id, do: "ring-2 ring-primary"}"}
                phx-click="select_solution"
                phx-value-index={idx}
              >
                <div class="flex justify-between items-center">
                  <div>
                    <span class="badge badge-primary badge-sm mr-2">#{solution.rank}</span>
                    <span class="font-medium">Score: {Float.round(solution.total_score, 2)}</span>
                  </div>
                  <div class="text-sm text-gray-500">
                    {format_price(solution.total_price)}
                  </div>
                </div>
                <div class="text-xs text-gray-500 mt-1">
                  {length(solution.modules)} modules
                </div>
              </div>
            <% end %>
          </div>
          
    <!-- Solution Details -->
          <div class="lg:col-span-2">
            <%= if @selected_solution do %>
              <div class="card bg-base-100 p-4">
                <div class="flex justify-between items-start mb-4">
                  <div>
                    <h3 class="text-lg font-semibold">Solution #{@selected_solution.rank}</h3>
                    <div class="text-sm text-gray-500">
                      Total Score:
                      <span class="font-mono">{Float.round(@selected_solution.total_score, 4)}</span>
                    </div>
                  </div>
                  <div class="flex gap-2">
                    <button class="btn btn-primary btn-sm" phx-click="export_eft">
                      Copy EFT
                    </button>
                    <button class="btn btn-secondary btn-sm" phx-click="export_json">
                      Copy JSON
                    </button>
                  </div>
                </div>
                
    <!-- Resource Usage -->
                <div class="mb-4">
                  <h4 class="font-medium mb-2">Resource Usage</h4>
                  <div class="grid grid-cols-3 gap-2 text-sm">
                    <div>
                      <span class="text-gray-500">CPU:</span>
                      {Float.round(@selected_solution.resource_usage.cpu, 1)} / {@constraints.cpu_capacity} tf
                    </div>
                    <div>
                      <span class="text-gray-500">Power:</span>
                      {Float.round(@selected_solution.resource_usage.power, 1)} / {@constraints.power_capacity} MW
                    </div>
                    <div>
                      <span class="text-gray-500">Calibration:</span>
                      {Float.round(@selected_solution.resource_usage.calibration, 1)} / {@constraints.calibration_capacity}
                    </div>
                  </div>
                </div>
                
    <!-- Modules -->
                <div>
                  <h4 class="font-medium mb-2">Fitted Modules</h4>
                  <div class="space-y-2">
                    <%= for {slot_type, label} <- [{:high, "High"}, {:med, "Med"}, {:low, "Low"}, {:rig, "Rig"}] do %>
                      <% slot_modules =
                        Enum.filter(@selected_solution.modules, &(&1.slot_type == slot_type)) %>
                      <%= if Enum.any?(slot_modules) do %>
                        <div>
                          <span class="badge badge-outline badge-sm">{label}</span>
                          <div class="ml-4 mt-1 space-y-1">
                            <%= for mod <- slot_modules do %>
                              <div class="flex justify-between text-sm">
                                <span>{mod.name}</span>
                                <span class="text-gray-500">
                                  {format_price(mod.price)}
                                  <span class="ml-2 text-xs">
                                    (score: {Float.round(mod.score, 2)})
                                  </span>
                                </span>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                </div>
                
    <!-- Total -->
                <div class="mt-4 pt-4 border-t border-base-300">
                  <div class="flex justify-between font-semibold">
                    <span>Total Price</span>
                    <span>{format_price(@selected_solution.total_price)}</span>
                  </div>
                </div>
              </div>
            <% else %>
              <div class="text-center py-8 text-gray-500">
                Select a solution to view details
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <div class="mt-6 flex justify-between items-center">
        <button class="btn btn-ghost" phx-click="set_step" phx-value-step="optimize">
          ← Back
        </button>
        <div class="flex gap-2">
          <%= if not Enum.empty?(@solutions) do %>
            <button class="btn btn-outline btn-sm" phx-click="export_all_json">
              Download All (JSON)
            </button>
          <% end %>
          <button class="btn btn-outline" phx-click="start_over">
            Start Over
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp step_label(:import), do: "Import"
  defp step_label(:constraints), do: "Constraints"
  defp step_label(:objectives), do: "Modules"
  defp step_label(:optimize), do: "Optimize"
  defp step_label(:results), do: "Results"

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

  defp error_to_string(:too_large), do: "File is too large (max 100KB)"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(:not_accepted), do: "Invalid file type. Use .txt or .eft files"
  defp error_to_string(err), do: "Upload error: #{inspect(err)}"

  defp format_elapsed(nil), do: "0.0s"

  defp format_elapsed(ms) when is_integer(ms) do
    seconds = ms / 1000

    if seconds < 60 do
      "#{Float.round(seconds, 1)}s"
    else
      minutes = div(ms, 60_000)
      remaining_seconds = rem(ms, 60_000) / 1000
      "#{minutes}m #{Float.round(remaining_seconds, 1)}s"
    end
  end
end
