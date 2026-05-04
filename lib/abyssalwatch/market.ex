defmodule Abyssalwatch.Market do
  use Ash.Domain

  resources do
    resource(Abyssalwatch.Market.Module)
    resource(Abyssalwatch.Market.ModuleType)
    resource(Abyssalwatch.Market.SDE.Version)
  end
end
