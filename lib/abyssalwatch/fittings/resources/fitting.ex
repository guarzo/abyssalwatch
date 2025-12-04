defmodule Abyssalwatch.Fittings.Fitting do
  @moduledoc """
  Represents a saved ship fitting.

  Fittings can be imported from various formats (EFT, DNA, XML, ESI)
  and used as input for optimization workflows.

  ## Format Support

  - **EFT**: Text format used for clipboard copy/paste
  - **DNA**: Compact single-line format for URLs and in-game links
  - **XML**: File format supporting multiple fittings
  - **ESI**: Direct import from EVE Online character fittings
  """

  use Ash.Resource,
    domain: Abyssalwatch.Fittings,
    data_layer: AshPostgres.DataLayer

  alias Abyssalwatch.Fittings.Parsers.{EFT, DNA, XML}

  postgres do
    table("fittings")
    repo(Abyssalwatch.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      description("Name of the fitting")
    end

    attribute :description, :string do
      allow_nil?(true)
      public?(true)
      description("Optional description of the fitting")
    end

    attribute :ship_type_id, :integer do
      public?(true)
      description("EVE Online ship type ID")
    end

    attribute :ship_type_name, :string do
      public?(true)
      description("Human-readable ship type name")
    end

    attribute :modules, :map do
      default(%{})
      public?(true)
      description("Full module details by slot")
    end

    attribute :dna, :string do
      public?(true)
      description("Compact DNA representation for sharing")
    end

    attribute :constraints, :map do
      default(%{})
      public?(true)
      description("Ship resource constraints (CPU, power, etc.)")
    end

    attribute :source, :atom do
      default(:manual)
      public?(true)
      constraints(one_of: [:manual, :eft, :dna, :xml, :esi])
      description("How the fitting was created")
    end

    attribute :source_format, :string do
      public?(true)
      description("Original import format content")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, Abyssalwatch.Accounts.User do
      allow_nil?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :name,
        :description,
        :ship_type_id,
        :ship_type_name,
        :modules,
        :dna,
        :constraints,
        :source,
        :source_format,
        :user_id
      ])
    end

    # Create a fitting from EFT format text.
    create :from_eft do
      accept([:name, :user_id])
      argument(:eft_text, :string, allow_nil?: false)

      change(fn changeset, _context ->
        eft_text = Ash.Changeset.get_argument(changeset, :eft_text)

        case EFT.parse(eft_text) do
          {:ok, parsed} ->
            changeset
            |> Ash.Changeset.change_attribute(:name, parsed.name)
            |> Ash.Changeset.change_attribute(:ship_type_name, parsed.ship_type)
            |> Ash.Changeset.change_attribute(:modules, modules_to_map(parsed))
            |> Ash.Changeset.change_attribute(:source, :eft)
            |> Ash.Changeset.change_attribute(:source_format, eft_text)

          {:error, reason} ->
            Ash.Changeset.add_error(changeset,
              field: :eft_text,
              message: reason
            )
        end
      end)
    end

    # Create a fitting from DNA format string.
    create :from_dna do
      accept([:user_id])
      argument(:dna_string, :string, allow_nil?: false)
      argument(:name, :string, allow_nil?: true)

      change(fn changeset, _context ->
        dna_string = Ash.Changeset.get_argument(changeset, :dna_string)
        name = Ash.Changeset.get_argument(changeset, :name)

        case DNA.parse(dna_string) do
          {:ok, parsed} ->
            fitting_name = name || "Imported Fit #{parsed.ship_type_id}"

            changeset
            |> Ash.Changeset.change_attribute(:name, fitting_name)
            |> Ash.Changeset.change_attribute(:ship_type_id, parsed.ship_type_id)
            |> Ash.Changeset.change_attribute(:modules, dna_to_modules_map(parsed))
            |> Ash.Changeset.change_attribute(:dna, dna_string)
            |> Ash.Changeset.change_attribute(:source, :dna)
            |> Ash.Changeset.change_attribute(:source_format, dna_string)

          {:error, reason} ->
            Ash.Changeset.add_error(changeset,
              field: :dna_string,
              message: reason
            )
        end
      end)
    end

    # Create a fitting from XML format string.
    create :from_xml do
      accept([:user_id])
      argument(:xml_content, :string, allow_nil?: false)

      change(fn changeset, _context ->
        xml_content = Ash.Changeset.get_argument(changeset, :xml_content)

        case XML.parse_single(xml_content) do
          {:ok, parsed} ->
            changeset
            |> Ash.Changeset.change_attribute(:name, parsed.name)
            |> Ash.Changeset.change_attribute(:description, parsed.description)
            |> Ash.Changeset.change_attribute(:ship_type_name, parsed.ship_type)
            |> Ash.Changeset.change_attribute(:modules, modules_to_map(parsed))
            |> Ash.Changeset.change_attribute(:source, :xml)
            |> Ash.Changeset.change_attribute(:source_format, xml_content)

          {:error, reason} ->
            Ash.Changeset.add_error(changeset,
              field: :xml_content,
              message: reason
            )
        end
      end)
    end

    # Create a fitting from ESI format (character fittings API).
    create :from_esi do
      accept([:user_id])
      argument(:esi_fitting, :map, allow_nil?: false)

      change(fn changeset, _context ->
        esi_fitting = Ash.Changeset.get_argument(changeset, :esi_fitting)

        changeset
        |> Ash.Changeset.change_attribute(:name, esi_fitting[:name] || esi_fitting["name"])
        |> Ash.Changeset.change_attribute(
          :description,
          esi_fitting[:description] || esi_fitting["description"]
        )
        |> Ash.Changeset.change_attribute(
          :ship_type_id,
          esi_fitting[:ship_type_id] || esi_fitting["ship_type_id"]
        )
        |> Ash.Changeset.change_attribute(:modules, esi_to_modules_map(esi_fitting))
        |> Ash.Changeset.change_attribute(:source, :esi)
        |> Ash.Changeset.change_attribute(:source_format, Jason.encode!(esi_fitting))
      end)
    end

    update :update do
      primary?(true)
      accept([:name, :description, :modules, :dna, :constraints])
    end

    update :update_constraints do
      accept([:constraints])
    end

    # Update the DNA representation based on current modules.
    update :regenerate_dna do
      require_atomic?(false)

      change(fn changeset, _context ->
        record = changeset.data

        if record.modules && record.ship_type_id do
          dna = DNA.encode(modules_map_to_dna_format(record.modules, record.ship_type_id))
          Ash.Changeset.change_attribute(changeset, :dna, dna)
        else
          changeset
        end
      end)
    end

    read :for_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
    end

    read :by_ship_type do
      argument(:ship_type_id, :integer, allow_nil?: false)
      filter(expr(ship_type_id == ^arg(:ship_type_id)))
    end
  end

  calculations do
    calculate :slot_counts, :map do
      calculation(fn records, _context ->
        Enum.map(records, fn record ->
          modules = record.modules || %{}

          %{
            high: count_slot(modules, "high_slots"),
            med: count_slot(modules, "med_slots"),
            low: count_slot(modules, "low_slots"),
            rig: count_slot(modules, "rig_slots")
          }
        end)
      end)

      description("Count of modules per slot type")
    end

    calculate :total_modules, :integer do
      calculation(fn records, _context ->
        Enum.map(records, fn record ->
          modules = record.modules || %{}

          Enum.sum([
            count_slot(modules, "high_slots"),
            count_slot(modules, "med_slots"),
            count_slot(modules, "low_slots"),
            count_slot(modules, "rig_slots")
          ])
        end)
      end)

      description("Total number of fitted modules")
    end

    calculate :ingame_link, :string do
      calculation(fn records, _context ->
        Enum.map(records, fn record ->
          cond do
            record.dna ->
              "<url=fitting:#{record.dna}>#{record.name}</url>"

            record.ship_type_id && record.modules ->
              dna = DNA.encode(modules_map_to_dna_format(record.modules, record.ship_type_id))
              "<url=fitting:#{dna}>#{record.name}</url>"

            true ->
              nil
          end
        end)
      end)

      description("In-game chat link for the fitting")
    end

    calculate :share_url, :string do
      calculation(fn records, _context ->
        base_url = Application.get_env(:abyssalwatch, :base_url, "https://abyssalwatch.com")

        Enum.map(records, fn record ->
          cond do
            record.dna ->
              "#{base_url}/fit/#{URI.encode(record.dna, &URI.char_unreserved?/1)}"

            record.ship_type_id && record.modules ->
              dna = DNA.encode(modules_map_to_dna_format(record.modules, record.ship_type_id))
              "#{base_url}/fit/#{URI.encode(dna, &URI.char_unreserved?/1)}"

            true ->
              nil
          end
        end)
      end)

      description("Shareable URL for the fitting")
    end

    calculate :eft_format, :string do
      calculation(fn records, _context ->
        Enum.map(records, fn record ->
          if record.modules do
            EFT.encode(%{
              name: record.name,
              ship_type: record.ship_type_name,
              low_slots: record.modules["low_slots"] || [],
              med_slots: record.modules["med_slots"] || [],
              high_slots: record.modules["high_slots"] || [],
              rig_slots: record.modules["rig_slots"] || [],
              subsystems: record.modules["subsystems"] || [],
              drones: record.modules["drones"] || [],
              cargo: record.modules["cargo"] || []
            })
          else
            nil
          end
        end)
      end)

      description("EFT format representation for clipboard")
    end
  end

  validations do
    validate(present(:name))
    validate(string_length(:name, min: 1, max: 100))
  end

  # Helper functions for format conversions

  defp modules_to_map(parsed) do
    %{
      "low_slots" => parsed[:low_slots] || parsed["low_slots"] || [],
      "med_slots" => parsed[:med_slots] || parsed["med_slots"] || [],
      "high_slots" => parsed[:high_slots] || parsed["high_slots"] || [],
      "rig_slots" => parsed[:rig_slots] || parsed["rig_slots"] || [],
      "subsystems" => parsed[:subsystems] || parsed["subsystems"] || [],
      "drones" => parsed[:drones] || parsed["drones"] || [],
      "cargo" => parsed[:cargo] || parsed["cargo"] || []
    }
  end

  defp dna_to_modules_map(parsed) do
    %{
      "low_slots" => parsed[:low_slots] || [],
      "med_slots" => parsed[:med_slots] || [],
      "high_slots" => parsed[:high_slots] || [],
      "rig_slots" => parsed[:rig_slots] || [],
      "subsystems" => parsed[:subsystems] || [],
      "drones" => parsed[:drones] || [],
      "cargo" => parsed[:cargo] || [],
      "charges" => parsed[:charges] || []
    }
  end

  defp esi_to_modules_map(esi_fitting) do
    items = esi_fitting[:items] || esi_fitting["items"] || []

    # Group items by flag (slot type)
    grouped =
      Enum.group_by(items, fn item ->
        flag = item[:flag] || item["flag"] || ""
        categorize_esi_flag(flag)
      end)

    %{
      "low_slots" => Map.get(grouped, :low, []),
      "med_slots" => Map.get(grouped, :med, []),
      "high_slots" => Map.get(grouped, :high, []),
      "rig_slots" => Map.get(grouped, :rig, []),
      "subsystems" => Map.get(grouped, :subsystem, []),
      "drones" => Map.get(grouped, :drone, []),
      "cargo" => Map.get(grouped, :cargo, [])
    }
  end

  defp categorize_esi_flag(flag) do
    cond do
      String.starts_with?(flag, "LoSlot") -> :low
      String.starts_with?(flag, "MedSlot") -> :med
      String.starts_with?(flag, "HiSlot") -> :high
      String.starts_with?(flag, "RigSlot") -> :rig
      String.starts_with?(flag, "SubSystem") -> :subsystem
      flag in ["DroneBay", "FighterBay"] -> :drone
      flag == "Cargo" -> :cargo
      true -> :other
    end
  end

  defp modules_map_to_dna_format(modules, ship_type_id) do
    %{
      ship_type_id: ship_type_id,
      subsystems: modules["subsystems"] || [],
      high_slots: modules["high_slots"] || [],
      med_slots: modules["med_slots"] || [],
      low_slots: modules["low_slots"] || [],
      rig_slots: modules["rig_slots"] || [],
      drones: modules["drones"] || [],
      cargo: modules["cargo"] || [],
      charges: modules["charges"] || []
    }
  end

  defp count_slot(modules, slot_key) do
    case modules[slot_key] do
      nil -> 0
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end
end
