defmodule Abyssalwatch.Market.SDE.Version do
  @moduledoc """
  Single-row marker tracking the most recently seeded EVE SDE.

  The row is identified by the constant `id = 1`. `Refresher` reads it on
  boot to decide whether to re-download the SDE.
  """
  use Ash.Resource,
    domain: Abyssalwatch.Market,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("sde_versions")
    repo(Abyssalwatch.Repo)
  end

  attributes do
    integer_primary_key(:id, writable?: true, generated?: false)

    attribute :build_number, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :etag, :string, public?: true
    attribute :last_modified, :utc_datetime, public?: true

    attribute :seeded_at, :utc_datetime do
      allow_nil?(false)
      public?(true)
    end

    attribute :type_count, :integer do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [:id, :build_number, :etag, :last_modified, :seeded_at, :type_count]
      upsert? true
      upsert_identity :_primary_key
    end
  end
end
