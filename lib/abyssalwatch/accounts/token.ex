defmodule Abyssalwatch.Accounts.Token do
  use Ash.Resource,
    domain: Abyssalwatch.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table("tokens")
    repo(Abyssalwatch.Repo)
  end

  actions do
    defaults([:read, :destroy])
  end
end
