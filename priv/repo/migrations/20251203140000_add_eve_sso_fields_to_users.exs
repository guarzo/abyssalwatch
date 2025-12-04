defmodule Abyssalwatch.Repo.Migrations.AddEveSsoFieldsToUsers do
  @moduledoc """
  Migration to add EVE SSO authentication fields to users table.

  This migration:
  1. Adds EVE character identity fields (character_id, character_name)
  2. Adds OAuth token fields (access_token, refresh_token, expires_at)
  3. Makes email/password nullable for EVE SSO users
  4. Adds unique index on character_id
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      # EVE Character Identity
      add :character_id, :integer
      add :character_name, :string
      add :character_owner_hash, :string

      # OAuth Tokens
      add :access_token, :text
      add :refresh_token, :text
      add :token_expires_at, :utc_datetime_usec

      # Activity tracking
      add :last_login_at, :utc_datetime_usec
    end

    # Make email nullable (EVE SSO users won't have email)
    alter table(:users) do
      modify :email, :citext, null: true
      modify :hashed_password, :string, null: true
    end

    # Add unique index for EVE character ID
    create unique_index(:users, [:character_id], where: "character_id IS NOT NULL")
  end
end
