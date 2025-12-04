defmodule Abyssalwatch.Repo.Migrations.CreateFittings do
  @moduledoc """
  Creates the fittings table for storing ship fittings.
  Part of Phase 3: Optimization Engine.
  """

  use Ecto.Migration

  def up do
    create table(:fittings, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :ship_type_id, :bigint
      add :ship_type_name, :text
      add :modules, :map, default: %{}
      add :dna, :text
      add :constraints, :map, default: %{}
      add :source, :text, default: "manual"
      add :source_format, :text

      add :user_id,
          references(:users, on_delete: :delete_all, on_update: :update_all, type: :uuid)

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:fittings, [:user_id])
    create index(:fittings, [:ship_type_id])
  end

  def down do
    drop_if_exists index(:fittings, [:ship_type_id])
    drop_if_exists index(:fittings, [:user_id])
    drop table(:fittings)
  end
end
