defmodule Abyssalwatch.Optimization.Solvers.Constraint do
  @moduledoc """
  Branch-and-bound constraint solver for optimal solutions.

  This solver systematically explores the solution space with intelligent
  pruning to find optimal or near-optimal solutions. More thorough than
  the heuristic solver but potentially slower.

  ## Algorithm:
  1. Group candidates by slot type
  2. Build a search tree exploring combinations
  3. Use bound estimation to prune unpromising branches
  4. Track best solutions found
  5. Return diverse top solutions

  ## Performance:
  - Typical runtime: 100ms - 30s depending on candidate count
  - Returns up to 10 diverse solutions
  - Better for final optimization decisions
  """

  alias Abyssalwatch.Optimization.Types.{Constraints, ResourceUsage, Solution}

  @behaviour Abyssalwatch.Optimization.Solvers.Behaviour

  @max_solutions 100
  @prune_threshold 0.80
  @max_iterations 50_000
  @diversity_threshold 0.3

  @doc """
  Solves the optimization problem using branch-and-bound.

  Returns a list of diverse solutions, ranked by total score.

  ## Options
    * `:max_solutions` - Maximum solutions to return (default: 10)
    * `:timeout_ms` - Maximum time to spend solving (default: 30000)
  """
  @impl true
  def solve(candidates, %Constraints{} = constraints, opts \\ []) do
    max_solutions = Keyword.get(opts, :max_solutions, 10)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    # Validate constraints
    case Constraints.validate(constraints) do
      {:error, reason} -> {:error, reason}
      :ok -> do_solve(candidates, constraints, max_solutions, timeout_ms)
    end
  end

  defp do_solve(candidates, constraints, max_solutions, timeout_ms) do
    # Group candidates by slot type and pre-sort by score
    grouped =
      candidates
      |> Enum.group_by(& &1.slot_type)
      |> Enum.map(fn {slot_type, mods} ->
        # Sort by score descending for better pruning
        sorted = Enum.sort_by(mods, & &1.score, :desc)
        {slot_type, sorted}
      end)
      |> Map.new()

    # Calculate upper bound for pruning
    upper_bound = calculate_upper_bound(grouped, constraints)

    # Initialize search state
    start_time = System.monotonic_time(:millisecond)

    initial_state = %{
      modules: [],
      usage: ResourceUsage.new(),
      score: 0.0
    }

    # Run branch and bound
    result =
      explore(
        grouped,
        constraints,
        initial_state,
        [],
        0.0,
        upper_bound,
        0,
        start_time,
        timeout_ms
      )

    # Process results
    solutions =
      result
      |> Enum.sort_by(& &1.total_score, :desc)
      |> Enum.take(@max_solutions)
      |> diversify_solutions()
      |> Enum.take(max_solutions)
      |> Enum.with_index(1)
      |> Enum.map(fn {solution, rank} -> %{solution | rank: rank} end)

    {:ok, solutions}
  end

  @impl true
  def name, do: :constraint

  @impl true
  def description, do: "Thorough branch-and-bound solver for optimal results"

  # Branch and bound exploration

  defp explore(
         _grouped,
         _constraints,
         state,
         solutions,
         _best,
         _upper,
         iterations,
         _start,
         _timeout
       )
       when iterations >= @max_iterations do
    maybe_add_solution(state, solutions)
  end

  defp explore(
         grouped,
         constraints,
         state,
         solutions,
         best_score,
         upper_bound,
         iterations,
         start,
         timeout
       ) do
    # Check timeout
    elapsed = System.monotonic_time(:millisecond) - start

    if elapsed >= timeout do
      maybe_add_solution(state, solutions)
    else
      # Check if we should prune this branch
      potential = state.score + remaining_potential(grouped, constraints, state)

      if should_prune?(potential, best_score, upper_bound) do
        solutions
      else
        # Try adding modules from each slot type
        slot_types = Map.keys(grouped)

        case find_unfilled_slot(slot_types, state, constraints) do
          nil ->
            # All slots filled or no more can be added
            maybe_add_solution(state, solutions)

          slot_type ->
            candidates = Map.get(grouped, slot_type, [])

            explore_slot(
              candidates,
              slot_type,
              grouped,
              constraints,
              state,
              solutions,
              best_score,
              upper_bound,
              iterations,
              start,
              timeout
            )
        end
      end
    end
  end

  defp explore_slot(
         [],
         _slot_type,
         _grouped,
         _constraints,
         state,
         solutions,
         _best,
         _upper,
         _iterations,
         _start,
         _timeout
       ) do
    maybe_add_solution(state, solutions)
  end

  defp explore_slot(
         [candidate | rest],
         slot_type,
         grouped,
         constraints,
         state,
         solutions,
         best_score,
         upper_bound,
         iterations,
         start,
         timeout
       ) do
    new_solutions =
      if ResourceUsage.can_add?(state.usage, candidate, constraints) do
        # Add this candidate and continue exploring
        new_state = %{
          modules: [candidate | state.modules],
          usage: ResourceUsage.add(state.usage, candidate),
          score: state.score + candidate.score
        }

        # Update best score if this is better
        new_best = max(best_score, new_state.score)

        # Continue exploring with this candidate added
        explore(
          grouped,
          constraints,
          new_state,
          solutions,
          new_best,
          upper_bound,
          iterations + 1,
          start,
          timeout
        )
      else
        solutions
      end

    # Also explore without adding this candidate (try next one)
    explore_slot(
      rest,
      slot_type,
      grouped,
      constraints,
      state,
      new_solutions,
      best_score,
      upper_bound,
      iterations + 1,
      start,
      timeout
    )
  end

  # Pruning logic

  defp should_prune?(potential, best_score, _upper_bound) when best_score > 0 do
    potential < best_score * @prune_threshold
  end

  defp should_prune?(_, _, _), do: false

  defp remaining_potential(grouped, constraints, state) do
    # Estimate maximum additional score we could achieve
    Enum.reduce(grouped, 0.0, fn {slot_type, candidates}, acc ->
      available = Map.get(constraints.available_slots, slot_type, 0)
      current = Map.get(state.usage.slots, slot_type, 0)
      remaining = available - current

      if remaining > 0 do
        # Sum of top N candidates' scores for this slot
        top_scores =
          candidates
          |> Enum.take(remaining)
          |> Enum.map(& &1.score)
          |> Enum.sum()

        acc + top_scores
      else
        acc
      end
    end)
  end

  defp calculate_upper_bound(grouped, constraints) do
    # Sum of best possible scores for each slot
    Enum.reduce(grouped, 0.0, fn {slot_type, candidates}, acc ->
      available = Map.get(constraints.available_slots, slot_type, 0)

      top_scores =
        candidates
        |> Enum.take(available)
        |> Enum.map(& &1.score)
        |> Enum.sum()

      acc + top_scores
    end)
  end

  # Helper functions

  defp find_unfilled_slot(slot_types, state, constraints) do
    Enum.find(slot_types, fn slot_type ->
      available = Map.get(constraints.available_slots, slot_type, 0)
      current = Map.get(state.usage.slots, slot_type, 0)
      current < available
    end)
  end

  defp maybe_add_solution(%{modules: []}, solutions), do: solutions

  defp maybe_add_solution(state, solutions) do
    solution = Solution.build(state.modules, state.usage)

    if length(solutions) < @max_solutions do
      [solution | solutions]
    else
      # Keep only best solutions
      [solution | solutions]
      |> Enum.sort_by(& &1.total_score, :desc)
      |> Enum.take(@max_solutions)
    end
  end

  defp diversify_solutions(solutions) do
    # Ensure variety by removing solutions that are too similar
    Enum.reduce(solutions, [], fn solution, acc ->
      if is_diverse?(solution, acc) do
        [solution | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp is_diverse?(solution, existing) do
    if Enum.empty?(existing) do
      true
    else
      solution_ids = solution.modules |> Enum.map(& &1.id) |> MapSet.new()

      Enum.all?(existing, fn other ->
        other_ids = other.modules |> Enum.map(& &1.id) |> MapSet.new()
        overlap = MapSet.intersection(solution_ids, other_ids) |> MapSet.size()
        total = max(MapSet.size(solution_ids), MapSet.size(other_ids))

        if total == 0 do
          true
        else
          overlap / total < 1 - @diversity_threshold
        end
      end)
    end
  end
end
