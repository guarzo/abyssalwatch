defmodule Abyssalwatch.Watchlists.Watchlist do
  @moduledoc """
  A watchlist defines criteria for monitoring abyssal modules.

  Users can create watchlists to track specific module types with
  attribute requirements and price thresholds. The system will
  notify users when matching modules appear on the market.
  """
  use Ash.Resource,
    domain: Abyssalwatch.Watchlists,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("watchlists")
    repo(Abyssalwatch.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      description("User-defined name for the watchlist")
    end

    attribute :module_type_id, :integer do
      allow_nil?(false)
      public?(true)
      description("EVE Online module type ID to monitor")
    end

    attribute :module_type_name, :string do
      public?(true)
      description("Human-readable module type name")
    end

    attribute :important_attributes, :map do
      default(%{})
      public?(true)
      description("Attributes with minimum required values (e.g., %{\"damage\" => 50})")
    end

    attribute :unimportant_attributes, :map do
      default(%{})
      public?(true)
      description("Attributes with maximum allowed values (e.g., %{\"cpu\" => 40})")
    end

    attribute :price_threshold, :decimal do
      public?(true)
      description("Maximum price in ISK (nil for no limit)")
    end

    attribute :min_score, :float do
      public?(true)
      description("Minimum TOPSIS score threshold (nil for no limit)")
    end

    attribute :notifications_enabled, :boolean do
      default(true)
      public?(true)
      description("Whether to send notifications for this watchlist")
    end

    attribute :last_checked_at, :utc_datetime_usec do
      public?(true)
      description("Last time this watchlist was checked for matches")
    end

    attribute :match_count, :integer do
      default(0)
      public?(true)
      description("Total number of modules that have matched this watchlist")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, Abyssalwatch.Accounts.User do
      allow_nil?(false)
      public?(true)
    end

    has_many :notifications, Abyssalwatch.Watchlists.Notification do
      destination_attribute(:watchlist_id)
    end
  end

  identities do
    identity(:unique_user_watchlist_name, [:user_id, :name])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :name,
        :module_type_id,
        :module_type_name,
        :important_attributes,
        :unimportant_attributes,
        :price_threshold,
        :min_score,
        :notifications_enabled
      ])

      argument(:user_id, :uuid, allow_nil?: false)

      change(manage_relationship(:user_id, :user, type: :append_and_remove))
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :important_attributes,
        :unimportant_attributes,
        :price_threshold,
        :min_score,
        :notifications_enabled
      ])
    end

    update :mark_checked do
      accept([])
      change(set_attribute(:last_checked_at, &DateTime.utc_now/0))
    end

    update :increment_match_count do
      accept([])
      require_atomic?(false)

      change(fn changeset, _context ->
        current_count = Ash.Changeset.get_attribute(changeset, :match_count) || 0
        Ash.Changeset.force_change_attribute(changeset, :match_count, current_count + 1)
      end)
    end

    update :toggle_notifications do
      accept([])
      require_atomic?(false)

      change(fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :notifications_enabled)
        Ash.Changeset.force_change_attribute(changeset, :notifications_enabled, !current)
      end)
    end

    read :for_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
    end

    read :active do
      description("Returns all watchlists with notifications enabled")
      filter(expr(notifications_enabled == true))
    end

    read :by_module_type do
      argument(:module_type_id, :integer, allow_nil?: false)
      filter(expr(module_type_id == ^arg(:module_type_id)))
    end

    read :get_by_id do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
      get?(true)
    end
  end

  validations do
    validate(present(:name))
    validate(present(:module_type_id))

    validate(numericality(:price_threshold, greater_than_or_equal_to: 0),
      where: [present(:price_threshold)]
    )

    validate(numericality(:min_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 1),
      where: [present(:min_score)]
    )
  end
end
