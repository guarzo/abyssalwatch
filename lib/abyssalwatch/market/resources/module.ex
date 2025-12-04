defmodule Abyssalwatch.Market.Module do
  @moduledoc """
  Represents an abyssal (mutated) module from the market.
  """
  use Ash.Resource,
    domain: Abyssalwatch.Market,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("modules")
    repo(Abyssalwatch.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :external_id, :string do
      allow_nil?(false)
      public?(true)
      description("External ID from Mutamarket")
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :type_id, :integer do
      allow_nil?(false)
      public?(true)
      description("EVE Online module type ID")
    end

    attribute :type_name, :string do
      public?(true)
      description("Human-readable module type name")
    end

    attribute :attributes, :map do
      default(%{})
      public?(true)
      description("Mutated attribute values")
    end

    attribute :price, :decimal do
      default(Decimal.new(0))
      public?(true)
      description("Listed price in ISK")
    end

    attribute :score, :float do
      default(0.0)
      public?(true)
      description("Calculated TOPSIS score")
    end

    attribute :source, :string do
      default("mutamarket")
      public?(true)
      description("Data source (e.g., 'mutamarket')")
    end

    attribute :available, :boolean do
      default(true)
      public?(true)
      description("Whether the module is currently available for sale")
    end

    attribute :contract_id, :string do
      public?(true)
      description("EVE Online contract ID if applicable")
    end

    attribute :seller_name, :string do
      public?(true)
      description("Name of the seller")
    end

    attribute :location, :string do
      public?(true)
      description("Station/Structure location")
    end

    attribute :last_seen, :utc_datetime_usec do
      public?(true)
      description("Last time this module was seen on the market")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_external_id, [:external_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :external_id,
        :name,
        :type_id,
        :type_name,
        :attributes,
        :price,
        :source,
        :contract_id,
        :seller_name,
        :location
      ])

      change(set_attribute(:last_seen, &DateTime.utc_now/0))
    end

    create :upsert do
      upsert?(true)
      upsert_identity(:unique_external_id)

      accept([
        :external_id,
        :name,
        :type_id,
        :type_name,
        :attributes,
        :price,
        :source,
        :contract_id,
        :seller_name,
        :location
      ])

      change(set_attribute(:last_seen, &DateTime.utc_now/0))
      change(set_attribute(:available, true))
    end

    update :update do
      primary?(true)
      accept([:attributes, :price, :score, :available, :last_seen])
    end

    update :update_score do
      accept([:score])
    end

    update :mark_unavailable do
      change(set_attribute(:available, false))
    end

    read :search do
      argument(:type_id, :integer, allow_nil?: false)
      argument(:min_price, :decimal)
      argument(:max_price, :decimal)
      argument(:min_score, :float)

      filter(expr(type_id == ^arg(:type_id) and available == true))
    end

    read :by_type do
      argument(:type_id, :integer, allow_nil?: false)
      filter(expr(type_id == ^arg(:type_id)))
    end

    read :by_external_id do
      argument(:external_id, :string, allow_nil?: false)
      filter(expr(external_id == ^arg(:external_id)))
      get?(true)
    end

    read :available do
      filter(expr(available == true))
    end
  end

  calculations do
    calculate :efficiency, :float do
      calculation(fn records, _context ->
        Enum.map(records, fn record ->
          price = Decimal.to_float(record.price || Decimal.new(0))

          if price > 0 do
            record.score / price * 1_000_000_000
          else
            0.0
          end
        end)
      end)

      description("Score per billion ISK")
    end
  end
end
