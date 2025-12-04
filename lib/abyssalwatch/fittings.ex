defmodule Abyssalwatch.Fittings do
  @moduledoc """
  The Fittings domain for AbyssalWatch.

  Manages ship fittings, including parsing from various formats
  (EFT, DNA, XML) and storage for optimization workflows.
  """

  use Ash.Domain

  resources do
    resource(Abyssalwatch.Fittings.Fitting)
  end
end
