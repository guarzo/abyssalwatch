# Script for populating the database with module types from EVE Online SDE.
#
# This script reads from the official EVE Online Static Data Export (SDE)
# to populate abyssal module types with accurate attribute metadata.
#
# Run with: mix run priv/repo/seeds.exs
#
# SDE must be downloaded first:
#   curl -sL "https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip" -o /tmp/sde.zip
#   unzip -o /tmp/sde.zip -d /tmp/sde/

alias Abyssalwatch.Market.ModuleType

defmodule SDELoader do
  @moduledoc """
  Loads data from EVE Online SDE JSON Lines files.
  """

  @sde_path "/tmp/sde"

  def load_types do
    read_jsonl("types.jsonl")
    |> Enum.reduce(%{}, fn item, acc ->
      Map.put(acc, item["_key"], item)
    end)
  end

  def load_groups do
    read_jsonl("groups.jsonl")
    |> Enum.reduce(%{}, fn item, acc ->
      Map.put(acc, item["_key"], item)
    end)
  end

  def load_dogma_attributes do
    read_jsonl("dogmaAttributes.jsonl")
    |> Enum.reduce(%{}, fn item, acc ->
      Map.put(acc, item["_key"], item)
    end)
  end

  def load_type_dogma do
    read_jsonl("typeDogma.jsonl")
    |> Enum.reduce(%{}, fn item, acc ->
      Map.put(acc, item["_key"], item)
    end)
  end

  defp read_jsonl(filename) do
    path = Path.join(@sde_path, filename)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.filter(&(&1 != ""))
      |> Stream.map(&Jason.decode!/1)
      |> Enum.to_list()
    else
      IO.puts("Warning: #{path} not found. Run the SDE download commands first.")
      []
    end
  end
end

defmodule AbyssalModuleSeeder do
  @moduledoc """
  Seeds abyssal module types from SDE data.
  """

  # Key attributes that are commonly modified by mutaplasmids
  @key_attributes %{
    # CPU and Power
    # CPU usage
    50 => "cpu",
    # Powergrid Usage
    30 => "powergrid",

    # Activation
    # Capacitor Need
    6 => "activation_cost",
    # Activation time
    73 => "duration",

    # Range
    # Optimal Range
    54 => "optimal_range",
    # Accuracy falloff
    158 => "falloff",

    # Speed/Propulsion
    # Maximum Velocity Bonus
    20 => "velocity_bonus",
    # Signature Radius Bonus
    554 => "signature_radius_bonus",
    # Speed Boost Factor
    796 => "speed_boost_factor",

    # Tank
    # Shield Capacity
    265 => "shield_hp",
    # Armor HP
    263 => "armor_hp",
    # Structure Hitpoints
    9 => "structure_hp",

    # Shield Booster
    # Shield Boost
    68 => "shield_bonus",

    # Armor Repairer
    # Armor Damage Amount
    84 => "armor_repair",

    # Damage Control
    271 => "hull_em_resist",
    272 => "hull_explosive_resist",
    273 => "hull_kinetic_resist",
    274 => "hull_thermal_resist",

    # Tackle
    # Warp Scramble Range
    588 => "scramble_range",
    # Warp Disrupt Range
    679 => "disrupt_range"
  }

  # Module group categories
  @group_categories %{
    # Warp Disruptor
    52 => "Tackle",
    # Stasis Webifier
    65 => "Tackle",
    # Gyrostabilizer
    59 => "Damage",
    # Heat Sink
    205 => "Damage",
    # Magnetic Field Stabilizer
    302 => "Damage",
    # Ballistic Control System
    367 => "Damage",
    # Entropic Radiation Sink
    1988 => "Damage",
    # Damage Control
    60 => "Tank",
    # Siege Module
    515 => "Capital",
    # Afterburner
    46 => "Propulsion",
    # Microwarpdrive
    58 => "Propulsion",
    # Shield Extender
    774 => "Shield",
    # Shield Booster
    77 => "Shield",
    # Armor Plates
    62 => "Armor",
    # Armor Repairer
    98 => "Armor",
    # Armor Hardener
    326 => "Armor",
    # Ancillary Armor Repairer
    1150 => "Armor"
  }

  @slot_types %{
    "high" => :high,
    "med" => :med,
    "medium" => :med,
    "low" => :low,
    "rig" => :rig
  }

  def seed(types, groups, dogma_attrs, type_dogma) do
    # Find all published Abyssal module types
    abyssal_types =
      types
      |> Enum.filter(fn {_id, t} ->
        name = get_in(t, ["name", "en"]) || ""
        String.starts_with?(name, "Abyssal ") and t["published"] == true
      end)
      |> Enum.reject(fn {_id, t} ->
        name = get_in(t, ["name", "en"]) || ""

        String.contains?(name, "Blueprint") or
          String.contains?(name, "Mining Crystal") or
          String.contains?(name, "Mining Laser") or
          String.contains?(name, "Strip Miner") or
          String.contains?(name, "Deep Core Miner") or
          String.contains?(name, "Corruption")
      end)

    IO.puts("Found #{length(abyssal_types)} abyssal module types in SDE")

    for {type_id, type_data} <- abyssal_types do
      seed_module_type(type_id, type_data, groups, dogma_attrs, type_dogma, types)
    end
  end

  defp seed_module_type(type_id, type_data, groups, dogma_attrs, type_dogma, all_types) do
    name = get_in(type_data, ["name", "en"])
    group_id = type_data["groupID"]
    group = groups[group_id]
    group_name = get_in(group, ["name", "en"]) || "Unknown"

    # Determine category from group
    category = Map.get(@group_categories, group_id, determine_category(name))

    # Determine slot type from group/name
    slot_type = determine_slot_type(group_name, name)

    # Get base attributes from a reference module in the same group
    base_attributes = get_base_attributes(group_id, dogma_attrs, type_dogma, all_types)

    attrs = %{
      eve_type_id: type_id,
      name: name,
      category: category,
      slot_type: slot_type,
      base_attributes: base_attributes
    }

    case Ash.create(ModuleType, attrs, upsert?: true, upsert_identity: :unique_eve_type_id) do
      {:ok, module_type} ->
        IO.puts("  ✓ #{module_type.name} (#{module_type.eve_type_id}) - #{category}/#{slot_type}")

      {:error, error} ->
        IO.puts("  ✗ Failed: #{name} - #{inspect(error)}")
    end
  end

  defp determine_category(name) do
    cond do
      String.contains?(name, "Webifier") -> "Tackle"
      String.contains?(name, "Scrambler") -> "Tackle"
      String.contains?(name, "Disruptor") -> "Tackle"
      String.contains?(name, "Damage Control") -> "Tank"
      String.contains?(name, "Stabilizer") -> "Damage"
      String.contains?(name, "Heat Sink") -> "Damage"
      String.contains?(name, "Gyro") -> "Damage"
      String.contains?(name, "Ballistic") -> "Damage"
      String.contains?(name, "Shield") -> "Shield"
      String.contains?(name, "Armor") -> "Armor"
      String.contains?(name, "Siege") -> "Capital"
      String.contains?(name, "Afterburner") -> "Propulsion"
      String.contains?(name, "MWD") or String.contains?(name, "Microwarpdrive") -> "Propulsion"
      true -> "Other"
    end
  end

  defp determine_slot_type(group_name, name) do
    group_lower = String.downcase(group_name)
    name_lower = String.downcase(name)

    cond do
      String.contains?(group_lower, "low") -> :low
      String.contains?(group_lower, "med") -> :med
      String.contains?(group_lower, "high") -> :high
      String.contains?(group_lower, "rig") -> :rig
      # Infer from module type
      String.contains?(name_lower, "stabilizer") -> :low
      String.contains?(name_lower, "heat sink") -> :low
      String.contains?(name_lower, "damage control") -> :low
      String.contains?(name_lower, "armor") -> :low
      String.contains?(name_lower, "webifier") -> :med
      String.contains?(name_lower, "scrambler") -> :med
      String.contains?(name_lower, "disruptor") -> :med
      String.contains?(name_lower, "shield") -> :med
      String.contains?(name_lower, "afterburner") -> :med
      String.contains?(name_lower, "microwarpdrive") -> :med
      true -> :med
    end
  end

  defp get_base_attributes(group_id, dogma_attrs, type_dogma, all_types) do
    # Find a T2 module in the same group to get attribute definitions
    reference_type =
      all_types
      |> Enum.find(fn {_id, t} ->
        # T2
        t["groupID"] == group_id and
          t["published"] == true and
          t["metaGroupID"] == 2 and
          not String.starts_with?(get_in(t, ["name", "en"]) || "", "Abyssal")
      end)

    case reference_type do
      {ref_id, _ref_data} ->
        type_attrs = type_dogma[ref_id]["dogmaAttributes"] || []

        type_attrs
        |> Enum.filter(fn attr -> Map.has_key?(@key_attributes, attr["attributeID"]) end)
        |> Enum.reduce(%{}, fn attr, acc ->
          attr_id = attr["attributeID"]
          attr_meta = dogma_attrs[attr_id] || %{}
          attr_name = @key_attributes[attr_id]

          direction = if attr_meta["highIsGood"], do: :higher_better, else: :lower_better

          display_name =
            get_in(attr_meta, ["displayName", "en"]) || attr_meta["name"] || attr_name

          Map.put(acc, attr_name, %{
            "attribute_id" => attr_id,
            "display_name" => display_name,
            "direction" => to_string(direction),
            "high_is_good" => attr_meta["highIsGood"]
          })
        end)

      nil ->
        %{}
    end
  end
end

# Check if SDE files exist
sde_path = "/tmp/sde"
required_files = ["types.jsonl", "groups.jsonl", "dogmaAttributes.jsonl", "typeDogma.jsonl"]

missing_files =
  Enum.filter(required_files, fn file ->
    not File.exists?(Path.join(sde_path, file))
  end)

if Enum.any?(missing_files) do
  IO.puts("""
  \n⚠️  SDE files not found. Please download them first:

    curl -sL "https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip" -o /tmp/sde.zip
    unzip -o /tmp/sde.zip -d /tmp/sde/

  Missing files: #{Enum.join(missing_files, ", ")}
  """)

  IO.puts("\n📦 Falling back to hardcoded module types...\n")

  # Fallback to basic hardcoded types
  fallback_types = [
    %{eve_type_id: 47702, name: "Abyssal Stasis Webifier", category: "Tackle", slot_type: :med},
    %{eve_type_id: 47732, name: "Abyssal Warp Scrambler", category: "Tackle", slot_type: :med},
    %{eve_type_id: 47736, name: "Abyssal Warp Disruptor", category: "Tackle", slot_type: :med},
    %{
      eve_type_id: 49722,
      name: "Abyssal Magnetic Field Stabilizer",
      category: "Damage",
      slot_type: :low
    },
    %{eve_type_id: 49726, name: "Abyssal Heat Sink", category: "Damage", slot_type: :low},
    %{eve_type_id: 49730, name: "Abyssal Gyrostabilizer", category: "Damage", slot_type: :low},
    %{
      eve_type_id: 49734,
      name: "Abyssal Entropic Radiation Sink",
      category: "Damage",
      slot_type: :low
    },
    %{
      eve_type_id: 49738,
      name: "Abyssal Ballistic Control System",
      category: "Damage",
      slot_type: :low
    },
    %{eve_type_id: 52227, name: "Abyssal Damage Control", category: "Tank", slot_type: :low},
    %{
      eve_type_id: 52230,
      name: "Abyssal Assault Damage Control",
      category: "Tank",
      slot_type: :low
    },
    %{eve_type_id: 56313, name: "Abyssal Siege Module", category: "Capital", slot_type: :high}
  ]

  IO.puts("Seeding #{length(fallback_types)} fallback module types...")

  for type <- fallback_types do
    attrs = Map.put(type, :base_attributes, %{})

    case Ash.create(ModuleType, attrs, upsert?: true, upsert_identity: :unique_eve_type_id) do
      {:ok, module_type} ->
        IO.puts("  ✓ #{module_type.name} (#{module_type.eve_type_id})")

      {:error, error} ->
        IO.puts("  ✗ Failed: #{type.name} - #{inspect(error)}")
    end
  end
else
  IO.puts("Loading SDE data...")
  types = SDELoader.load_types()
  IO.puts("  Loaded #{map_size(types)} types")

  groups = SDELoader.load_groups()
  IO.puts("  Loaded #{map_size(groups)} groups")

  dogma_attrs = SDELoader.load_dogma_attributes()
  IO.puts("  Loaded #{map_size(dogma_attrs)} dogma attributes")

  type_dogma = SDELoader.load_type_dogma()
  IO.puts("  Loaded #{map_size(type_dogma)} type dogma entries")

  IO.puts("\nSeeding abyssal module types from SDE...")
  AbyssalModuleSeeder.seed(types, groups, dogma_attrs, type_dogma)
end

IO.puts("\n✅ Seeding complete!")
