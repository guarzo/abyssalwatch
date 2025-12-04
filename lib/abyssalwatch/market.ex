defmodule Abyssalwatch.Market do
  use Ash.Domain

  resources do
    resource(Abyssalwatch.Market.Module)
    resource(Abyssalwatch.Market.ModuleType)
  end
end
