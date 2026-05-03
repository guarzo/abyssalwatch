defmodule Abyssalwatch.Repo.Migrations.FixUsersCharacterIdUniqueIndex do
  @moduledoc """
  Replaces the partial unique index on users.character_id with a full unique
  index so that Ash's upsert (ON CONFLICT (character_id)) has a matching
  conflict target. Postgres unique indexes already allow multiple NULLs, so
  the WHERE predicate was redundant.
  """

  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:users, [:character_id])
    create unique_index(:users, [:character_id])
  end

  def down do
    drop_if_exists unique_index(:users, [:character_id])
    create unique_index(:users, [:character_id], where: "character_id IS NOT NULL")
  end
end
