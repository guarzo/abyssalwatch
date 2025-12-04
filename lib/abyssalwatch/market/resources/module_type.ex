defmodule Abyssalwatch.Market.ModuleType do
  @moduledoc """
  Represents an EVE Online module type that can be mutated with mutaplasmids.
  """
  use Ash.Resource,
    domain: Abyssalwatch.Market,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("module_types")
    repo(Abyssalwatch.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :eve_type_id, :integer do
      allow_nil?(false)
      public?(true)
      description("EVE Online type ID")
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :category, :string do
      allow_nil?(false)
      public?(true)
      description("Module category (e.g., 'Propulsion', 'Tackle', 'Shield', 'Armor')")
    end

    attribute :slot_type, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:high, :med, :low, :rig])
      description("Ship slot type")
    end

    attribute :base_attributes, :map do
      default(%{})
      public?(true)
      description("Base attribute definitions with metadata")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_eve_type_id, [:eve_type_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:eve_type_id, :name, :category, :slot_type, :base_attributes])
    end

    update :update do
      primary?(true)
      accept([:name, :category, :slot_type, :base_attributes])
    end

    read :by_eve_type_id do
      argument(:eve_type_id, :integer, allow_nil?: false)
      filter(expr(eve_type_id == ^arg(:eve_type_id)))
      get?(true)
    end

    read :by_category do
      argument(:category, :string, allow_nil?: false)
      filter(expr(category == ^arg(:category)))
    end

    read :by_slot_type do
      argument(:slot_type, :atom, allow_nil?: false)
      filter(expr(slot_type == ^arg(:slot_type)))
    end
  end
end
