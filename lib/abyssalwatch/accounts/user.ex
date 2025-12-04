defmodule Abyssalwatch.Accounts.User do
  @moduledoc """
  User resource linked to EVE Online character via SSO.

  Users authenticate through EVE SSO OAuth2, which provides:
  - Character identity (ID, name, portrait)
  - Access tokens for ESI API calls
  - Refresh tokens for token renewal
  """

  use Ash.Resource,
    domain: Abyssalwatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("users")
    repo(Abyssalwatch.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    # EVE Character Identity
    attribute :character_id, :integer do
      allow_nil?(false)
      public?(true)
      description("EVE Online character ID")
    end

    attribute :character_name, :string do
      allow_nil?(false)
      public?(true)
      description("EVE Online character name")
    end

    attribute :character_owner_hash, :string do
      allow_nil?(true)
      description("Owner hash to detect character transfers")
    end

    # OAuth Tokens (sensitive)
    attribute :access_token, :string do
      allow_nil?(true)
      sensitive?(true)
      description("EVE SSO access token for ESI API")
    end

    attribute :refresh_token, :string do
      allow_nil?(true)
      sensitive?(true)
      description("EVE SSO refresh token for token renewal")
    end

    attribute :token_expires_at, :utc_datetime_usec do
      allow_nil?(true)
      description("When the access token expires")
    end

    # Legacy fields for migration compatibility
    attribute :email, :ci_string do
      allow_nil?(true)
      public?(true)
      description("Legacy email field (deprecated)")
    end

    attribute :hashed_password, :string do
      allow_nil?(true)
      sensitive?(true)
      description("Legacy password field (deprecated)")
    end

    attribute :username, :string do
      allow_nil?(true)
      public?(true)
      description("Optional display name (defaults to character_name)")
    end

    attribute :last_login_at, :utc_datetime_usec do
      allow_nil?(true)
      description("Last successful login timestamp")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_character_id, [:character_id])
    # Keep email identity for legacy users
    identity(:unique_email, [:email], where: expr(not is_nil(email)))
  end

  relationships do
    has_many :watchlists, Abyssalwatch.Watchlists.Watchlist
    has_many :fittings, Abyssalwatch.Fittings.Fitting
    has_many :notifications, Abyssalwatch.Watchlists.Notification
  end

  actions do
    defaults([:read])

    # Create or update a user from EVE SSO authentication.
    # Uses upsert to handle returning users.
    create :from_eve_sso do
      accept([
        :character_id,
        :character_name,
        :character_owner_hash,
        :access_token,
        :refresh_token,
        :token_expires_at
      ])

      upsert?(true)
      upsert_identity(:unique_character_id)

      upsert_fields([
        :character_name,
        :character_owner_hash,
        :access_token,
        :refresh_token,
        :token_expires_at,
        :last_login_at
      ])

      change(set_attribute(:last_login_at, &DateTime.utc_now/0))
    end

    # Update OAuth tokens after refresh.
    update :refresh_tokens do
      accept([:access_token, :refresh_token, :token_expires_at])
    end

    # Update user's display name.
    update :update_username do
      accept([:username])
    end

    read :by_character_id do
      argument(:character_id, :integer, allow_nil?: false)
      get?(true)
      filter(expr(character_id == ^arg(:character_id)))
    end

    read :by_id do
      argument(:id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    # Legacy action for email lookup (Phase 4 transition)
    read :by_email do
      argument(:email, :ci_string, allow_nil?: false)
      get?(true)
      filter(expr(email == ^arg(:email)))
    end
  end

  calculations do
    calculate :display_name, :string do
      calculation(fn records, _context ->
        Enum.map(records, fn record ->
          record.username || record.character_name
        end)
      end)

      description("User's display name (username or character name)")
    end

    calculate :portrait_url, :string do
      calculation(fn records, _context ->
        Enum.map(records, fn record ->
          "https://images.evetech.net/characters/#{record.character_id}/portrait?size=128"
        end)
      end)

      description("URL to the character's portrait image")
    end

    calculate :token_expired?, :boolean do
      calculation(fn records, _context ->
        now = DateTime.utc_now()

        Enum.map(records, fn record ->
          case record.token_expires_at do
            nil -> true
            expires_at -> DateTime.compare(expires_at, now) == :lt
          end
        end)
      end)

      description("Whether the access token has expired")
    end

    calculate :token_needs_refresh?, :boolean do
      calculation(fn records, _context ->
        # Refresh if expiring within 5 minutes
        threshold = DateTime.add(DateTime.utc_now(), 5, :minute)

        Enum.map(records, fn record ->
          case record.token_expires_at do
            nil -> true
            expires_at -> DateTime.compare(expires_at, threshold) == :lt
          end
        end)
      end)

      description("Whether the token should be proactively refreshed")
    end
  end

  validations do
    validate(present(:character_id), on: :create)
    validate(present(:character_name), on: :create)
  end
end
