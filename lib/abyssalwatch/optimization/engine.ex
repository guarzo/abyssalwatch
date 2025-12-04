defmodule Abyssalwatch.Optimization.Engine do
  @moduledoc """
  Main coordination point for ship fitting optimization.

  The Engine provides a unified interface for optimizing ship fittings
  using different solver strategies. It handles validation, solver
  selection, and result formatting.

  ## Usage

      candidates = [%ModuleCandidate{...}, ...]
      constraints = Constraints.new(%{cpu_capacity: 400, power_capacity: 1000, ...})

      {:ok, result} = Engine.optimize(candidates, constraints, mode: :heuristic)
      # result.solutions contains ranked solutions

  ## Solver Modes

    * `:heuristic` - Fast greedy solver, good for interactive use (~100ms)
    * `:constraint` - Thorough branch-and-bound, better for final decisions (~1-30s)
  """

  alias Abyssalwatch.Optimization.Types.{ModuleCandidate, Constraints, Solution}
  alias Abyssalwatch.Optimization.Solvers.{Heuristic, Constraint}

  @type solver_mode :: :heuristic | :constraint

  @type optimization_result :: %{
          solutions: [Solution.t()],
          mode: solver_mode(),
          solved_at: DateTime.t(),
          candidate_count: non_neg_integer(),
          solve_time_ms: non_neg_integer()
        }

  @doc """
  Optimizes a ship fitting given candidate modules and constraints.

  Returns `{:ok, result}` with solutions and metadata, or `{:error, reason}`.

  ## Options

    * `:mode` - Solver mode, either `:heuristic` (default) or `:constraint`
    * `:max_solutions` - Maximum number of solutions to return
    * `:timeout_ms` - Maximum time for constraint solver (default: 30000)

  ## Examples

      iex> Engine.optimize(candidates, constraints)
      {:ok, %{solutions: [...], mode: :heuristic, ...}}

      iex> Engine.optimize(candidates, constraints, mode: :constraint)
      {:ok, %{solutions: [...], mode: :constraint, ...}}
  """
  @spec optimize([ModuleCandidate.t()], Constraints.t(), keyword()) ::
          {:ok, optimization_result()} | {:error, term()}
  def optimize(candidates, constraints, opts \\ [])

  def optimize(candidates, %Constraints{} = constraints, opts) do
    mode = Keyword.get(opts, :mode, :heuristic)

    with :ok <- validate_request(candidates, constraints) do
      start_time = System.monotonic_time(:millisecond)

      result =
        case mode do
          :heuristic -> Heuristic.solve(candidates, constraints, opts)
          :constraint -> Constraint.solve(candidates, constraints, opts)
          other -> {:error, "Unknown solver mode: #{inspect(other)}"}
        end

      end_time = System.monotonic_time(:millisecond)
      solve_time = end_time - start_time

      case result do
        {:ok, solutions} ->
          {:ok,
           %{
             solutions: solutions,
             mode: mode,
             solved_at: DateTime.utc_now(),
             candidate_count: length(candidates),
             solve_time_ms: solve_time
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns available solver modes with their descriptions.
  """
  @spec available_solvers() :: [{solver_mode(), String.t()}]
  def available_solvers do
    [
      {:heuristic, Heuristic.description()},
      {:constraint, Constraint.description()}
    ]
  end

  @doc """
  Validates optimization request parameters.

  Checks that:
  - Candidates list is not empty
  - Constraints have valid capacities
  - At least one slot is available
  """
  @spec validate_request([ModuleCandidate.t()], Constraints.t()) :: :ok | {:error, String.t()}
  def validate_request(candidates, %Constraints{} = constraints) do
    cond do
      Enum.empty?(candidates) ->
        {:error, "No module candidates provided"}

      constraints.cpu_capacity <= 0 ->
        {:error, "CPU capacity must be positive"}

      constraints.power_capacity <= 0 ->
        {:error, "Power capacity must be positive"}

      all_slots_zero?(constraints.available_slots) ->
        {:error, "At least one slot type must be available"}

      true ->
        :ok
    end
  end

  @doc """
  Prepares module candidates from scored modules.

  Takes the output from TOPSIS scoring and converts to ModuleCandidates
  suitable for optimization.

  ## Parameters

    * `scored_modules` - List of `%{module: map, score: float}` from Topsis.score/2
    * `slot_type` - The slot type for these modules (:high, :med, :low, :rig)
  """
  @spec prepare_candidates([map()], atom()) :: [ModuleCandidate.t()]
  def prepare_candidates(scored_modules, slot_type) do
    ModuleCandidate.from_scored_modules(scored_modules, slot_type)
  end

  @doc """
  Combines candidates from multiple module types.

  Useful when optimizing across different module categories.
  """
  @spec combine_candidates([[ModuleCandidate.t()]]) :: [ModuleCandidate.t()]
  def combine_candidates(candidate_lists) do
    List.flatten(candidate_lists)
  end

  @doc """
  Exports a solution to EFT format.

  Returns the fitting as an EFT-formatted string suitable for
  pasting into EVE Online.
  """
  @spec export_to_eft(Solution.t(), String.t(), String.t()) :: String.t()
  def export_to_eft(%Solution{} = solution, ship_name, fit_name) do
    modules_by_slot = Enum.group_by(solution.modules, & &1.slot_type)

    sections = [
      "[#{ship_name}, #{fit_name}]",
      "",
      format_slot_section(modules_by_slot[:low]),
      "",
      format_slot_section(modules_by_slot[:med]),
      "",
      format_slot_section(modules_by_slot[:high]),
      "",
      format_slot_section(modules_by_slot[:rig])
    ]

    Enum.join(sections, "\n") |> String.trim()
  end

  @doc """
  Exports a solution to JSON format.

  Returns a map suitable for JSON encoding with all solution details,
  resource usage, and individual module information.

  ## Example Output

      %{
        "rank" => 1,
        "total_score" => 3.45,
        "total_price" => "1500000000",
        "efficiency" => 0.0023,
        "resource_usage" => %{
          "cpu" => 350.5,
          "power" => 890.2,
          "calibration" => 200.0
        },
        "modules" => [
          %{
            "name" => "Abyssal Damage Control",
            "slot_type" => "low",
            "price" => "500000000",
            "score" => 1.15,
            "attributes" => %{...}
          }
        ]
      }
  """
  @spec export_to_json(Solution.t(), map()) :: map()
  def export_to_json(%Solution{} = solution, opts \\ %{}) do
    include_attributes = Map.get(opts, :include_attributes, true)

    %{
      "id" => solution.id,
      "rank" => solution.rank,
      "total_score" => Float.round(solution.total_score, 4),
      "total_price" => Decimal.to_string(solution.total_price),
      "total_price_formatted" => format_isk(solution.total_price),
      "efficiency" => Float.round(solution.efficiency, 6),
      "module_count" => length(solution.modules),
      "resource_usage" => %{
        "cpu" => Float.round(solution.resource_usage.cpu, 2),
        "power" => Float.round(solution.resource_usage.power, 2),
        "calibration" => Float.round(solution.resource_usage.calibration, 2),
        "slots" => %{
          "high" => solution.resource_usage.slots.high,
          "med" => solution.resource_usage.slots.med,
          "low" => solution.resource_usage.slots.low,
          "rig" => solution.resource_usage.slots.rig
        }
      },
      "modules" => Enum.map(solution.modules, &module_to_json(&1, include_attributes)),
      "score_breakdown" => solution.score_breakdown
    }
  end

  @doc """
  Exports multiple solutions to JSON format.

  Useful for exporting all solutions from an optimization run.
  """
  @spec export_solutions_to_json([Solution.t()], String.t(), String.t(), map()) :: map()
  def export_solutions_to_json(solutions, ship_name, fit_name, opts \\ %{}) do
    %{
      "ship_name" => ship_name,
      "fit_name" => fit_name,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "solution_count" => length(solutions),
      "solutions" => Enum.map(solutions, &export_to_json(&1, opts))
    }
  end

  defp module_to_json(module, include_attributes) do
    base = %{
      "id" => module.id,
      "external_id" => module.external_id,
      "name" => module.name,
      "type_id" => module.type_id,
      "slot_type" => Atom.to_string(module.slot_type),
      "price" => Decimal.to_string(module.price),
      "price_formatted" => format_isk(module.price),
      "score" => Float.round(module.score, 4),
      "efficiency" => Float.round(module.efficiency, 6),
      "cpu_usage" => module.cpu_usage,
      "power_usage" => module.power_usage,
      "calibration_usage" => module.calibration_usage
    }

    if include_attributes do
      Map.put(base, "attributes", module.attributes)
    else
      base
    end
  end

  defp format_isk(%Decimal{} = price) do
    price_float = Decimal.to_float(price)

    cond do
      price_float >= 1_000_000_000 ->
        "#{Float.round(price_float / 1_000_000_000, 2)}B ISK"

      price_float >= 1_000_000 ->
        "#{Float.round(price_float / 1_000_000, 2)}M ISK"

      price_float >= 1_000 ->
        "#{Float.round(price_float / 1_000, 1)}K ISK"

      true ->
        "#{round(price_float)} ISK"
    end
  end

  defp format_isk(_), do: "N/A"

  defp format_slot_section(nil), do: ""
  defp format_slot_section([]), do: ""

  defp format_slot_section(modules) do
    modules
    |> Enum.map(& &1.name)
    |> Enum.join("\n")
  end

  defp all_slots_zero?(slots) do
    Enum.all?(Map.values(slots), &(&1 == 0))
  end
end
