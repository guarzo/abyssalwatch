defmodule Abyssalwatch.Optimization.Solvers.Behaviour do
  @moduledoc """
  Behaviour definition for optimization solvers.

  All solvers must implement this behaviour to be usable
  by the optimization engine.
  """

  alias Abyssalwatch.Optimization.Types.{ModuleCandidate, Constraints, Solution}

  @doc """
  Solves the optimization problem given candidates and constraints.

  Returns `{:ok, solutions}` with a list of ranked solutions,
  or `{:error, reason}` if solving fails.
  """
  @callback solve(
              candidates :: [ModuleCandidate.t()],
              constraints :: Constraints.t(),
              opts :: keyword()
            ) :: {:ok, [Solution.t()]} | {:error, term()}

  @doc """
  Returns the solver's name as an atom.
  """
  @callback name() :: atom()

  @doc """
  Returns a human-readable description of the solver.
  """
  @callback description() :: String.t()
end
