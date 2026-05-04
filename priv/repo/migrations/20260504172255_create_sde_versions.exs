defmodule Abyssalwatch.Repo.Migrations.CreateSdeVersions do
  use Ecto.Migration

  def change do
    create table(:sde_versions, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :build_number, :bigint, null: false
      add :etag, :string
      add :last_modified, :utc_datetime
      add :seeded_at, :utc_datetime, null: false
      add :type_count, :integer, null: false
    end
  end
end
