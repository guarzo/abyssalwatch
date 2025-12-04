defmodule Abyssalwatch.Optimization.Solvers.Heuristic do
  @moduledoc """
  Greedy heuristic solver for ship fitting optimization.

  This solver uses a fast greedy approach to find a good (but not necessarily
  optimal) solution. It's suitable for rapid results when exploring options.

  ## Algorithm:
  1. Calculate efficiency (score/price) for all candidates
  2. Sort candidates by efficiency descending
  3. Greedily select modules that satisfy constraints
  4. Generate alternative solutions (budget-focused, balanced)

  ## Performance:
  - Typical runtime: < 100ms
  - Returns 1-3 solutions
  - Good for interactive use
  """

  alias Abyssalwatch.Optimization.Types.{Constraints, ResourceUsage, Solution}

  @behaviour Abyssalwatch.Optimization.Solvers.Behaviour

  @doc """
  Solves the optimization problem using a greedy heuristic.

  Returns a list of solutions, typically 1-3, ranked by total score.

  ## Options
    * `:max_solutions` - Maximum number of solutions to return (default: 3)
  """
  @impl true
  def solve(candidates, %Constraints{} = constraints, opts \\ []) do
    max_solutions = Keyword.get(opts, :max_solutions, 3)

    # Validate constraints
    case Constraints.validate(constraints) do
      {:error, reason} -> {:error, reason}
      :ok -> do_solve(candidates, constraints, max_solutions)
    end
  end

  defp do_solve(candidates, constraints, max_solutions) do
    # Group candidates by slot type
    grouped = Enum.group_by(candidates, & &1.slot_type)

    # Generate primary solution (efficiency-focused)
    primary =
      grouped
      |> sort_by_efficiency()
      |> greedy_select(constraints)

    # Generate alternative solutions
    budget_solution =
      grouped
      |> sort_by_price()
      |> greedy_select(constraints)

    score_solution =
      grouped
      |> sort_by_score()
      |> greedy_select(constraints)

    # Collect unique solutions
    solutions =
      [primary, budget_solution, score_solution]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&solution_signature/1)
      |> Enum.sort_by(& &1.total_score, :desc)
      |> Enum.take(max_solutions)
      |> Enum.with_index(1)
      |> Enum.map(fn {solution, rank} -> %{solution | rank: rank} end)

    {:ok, solutions}
  end

  @doc """
  Returns solver metadata.
  """
  @impl true
  def name, do: :heuristic

  @impl true
  def description, do: "Fast greedy solver for quick results"

  # Sorting strategies

  defp sort_by_efficiency(grouped) do
    Enum.map(grouped, fn {slot_type, candidates} ->
      sorted = Enum.sort_by(candidates, & &1.efficiency, :desc)
      {slot_type, sorted}
    end)
    |> Map.new()
  end

  defp sort_by_price(grouped) do
    Enum.map(grouped, fn {slot_type, candidates} ->
      sorted = Enum.sort_by(candidates, &Decimal.to_float(&1.price), :asc)
      {slot_type, sorted}
    end)
    |> Map.new()
  end

  defp sort_by_score(grouped) do
    Enum.map(grouped, fn {slot_type, candidates} ->
      sorted = Enum.sort_by(candidates, & &1.score, :desc)
      {slot_type, sorted}
    end)
    |> Map.new()
  end

  # Greedy selection algorithm

  defp greedy_select(sorted_grouped, constraints) do
    initial_state = %{
      modules: [],
      usage: ResourceUsage.new()
    }

    # Process each slot type, selecting modules greedily
    state =
      Enum.reduce(sorted_grouped, initial_state, fn {slot_type, candidates}, state ->
        select_for_slot(candidates, slot_type, constraints, state)
      end)

    if Enum.empty?(state.modules) do
      nil
    else
      Solution.build(state.modules, state.usage)
    end
  end

  defp select_for_slot(candidates, slot_type, constraints, state) do
    available = Map.get(constraints.available_slots, slot_type, 0)
    current = Map.get(state.usage.slots, slot_type, 0)
    slots_remaining = available - current

    if slots_remaining <= 0 do
      state
    else
      # Try to fill remaining slots
      Enum.reduce_while(candidates, state, fn candidate, acc ->
        if Map.get(acc.usage.slots, slot_type, 0) >= available do
          {:halt, acc}
        else
          if ResourceUsage.can_add?(acc.usage, candidate, constraints) do
            new_state = %{
              modules: [candidate | acc.modules],
              usage: ResourceUsage.add(acc.usage, candidate)
            }

            {:cont, new_state}
          else
            {:cont, acc}
          end
        end
      end)
    end
  end

  # Helper to identify unique solutions

  defp solution_signature(%Solution{modules: modules}) do
    modules
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> Enum.join(",")
  end
end
