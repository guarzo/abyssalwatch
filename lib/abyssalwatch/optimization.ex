defmodule Abyssalwatch.Optimization do
  @moduledoc """
  The Optimization domain for AbyssalWatch.

  Provides ship fitting optimization using abyssal modules,
  supporting multiple solver strategies for different use cases.

  Note: This domain contains no Ash resources - it's a purely functional
  module providing optimization algorithms (heuristic and constraint solvers).
  """

  @doc """
  Optimizes a ship fitting with the given candidates and constraints.

  Delegates to `Abyssalwatch.Optimization.Engine.optimize/3`.
  """
  defdelegate optimize(candidates, constraints, opts \\ []),
    to: Abyssalwatch.Optimization.Engine

  @doc """
  Prepares module candidates from scored modules.

  Delegates to `Abyssalwatch.Optimization.Engine.prepare_candidates/2`.
  """
  defdelegate prepare_candidates(scored_modules, slot_type),
    to: Abyssalwatch.Optimization.Engine

  @doc """
  Exports a solution to EFT format.

  Delegates to `Abyssalwatch.Optimization.Engine.export_to_eft/3`.
  """
  defdelegate export_to_eft(solution, ship_name, fit_name),
    to: Abyssalwatch.Optimization.Engine

  @doc """
  Exports a solution to JSON format.

  Delegates to `Abyssalwatch.Optimization.Engine.export_to_json/2`.
  """
  defdelegate export_to_json(solution, opts \\ %{}),
    to: Abyssalwatch.Optimization.Engine

  @doc """
  Exports multiple solutions to JSON format.

  Delegates to `Abyssalwatch.Optimization.Engine.export_solutions_to_json/4`.
  """
  defdelegate export_solutions_to_json(solutions, ship_name, fit_name, opts \\ %{}),
    to: Abyssalwatch.Optimization.Engine
end
