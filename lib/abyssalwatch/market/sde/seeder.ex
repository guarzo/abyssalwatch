defmodule Abyssalwatch.Market.SDE.Seeder do
  @moduledoc """
  Seeds `Abyssalwatch.Market.ModuleType` rows.

  Two entry points:

    * `seed_from_sde/1` — uses the full SDE under the given path (defaults to
      `/tmp/sde`). Discovers all published Abyssal module types from the SDE
      and derives base attributes from a T2 reference module in the same
      group.

    * `seed_fallback/0` — seeds a hardcoded list of common Abyssal modules
      with empty `base_attributes`. Used when the SDE files are unavailable.

  Both upsert by `:unique_eve_type_id`, so they are safe to re-run.

  Returns `{ok_count, error_count}` from each entry point.
  """

  alias Abyssalwatch.Market.ModuleType
  alias Abyssalwatch.Market.SDE.Loader

  # Key attributes commonly modified by mutaplasmids.
  # Map of EVE dogma attribute ID -> internal attribute name.
  @key_attributes %{
    50 => "cpu",
    30 => "powergrid",
    6 => "activation_cost",
    73 => "duration",
    54 => "optimal_range",
    158 => "falloff",
    20 => "velocity_bonus",
    554 => "signature_radius_bonus",
    796 => "speed_boost_factor",
    265 => "shield_hp",
    263 => "armor_hp",
    9 => "structure_hp",
    68 => "shield_bonus",
    84 => "armor_repair",
    271 => "hull_em_resist",
    272 => "hull_explosive_resist",
    273 => "hull_kinetic_resist",
    274 => "hull_thermal_resist",
    588 => "scramble_range",
    679 => "disrupt_range"
  }

  @group_categories %{
    52 => "Tackle",
    65 => "Tackle",
    59 => "Damage",
    205 => "Damage",
    302 => "Damage",
    367 => "Damage",
    1988 => "Damage",
    60 => "Tank",
    515 => "Capital",
    46 => "Propulsion",
    58 => "Propulsion",
    774 => "Shield",
    77 => "Shield",
    62 => "Armor",
    98 => "Armor",
    326 => "Armor",
    1150 => "Armor"
  }

  @fallback_types [
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

  @doc """
  Seed from a full SDE on disk. Defaults to `/tmp/sde`.

  Returns `{:ok, {ok_count, error_count}}` on success or
  `{:error, {:missing_files, [...]}}` if SDE files aren't present.
  """
  def seed_from_sde(sde_path \\ Loader.default_path()) do
    case Loader.load_all(sde_path) do
      {:ok, %{types: types, groups: groups, dogma_attrs: dogma_attrs, type_dogma: type_dogma}} ->
        IO.puts(
          "Loaded SDE from #{sde_path}: #{map_size(types)} types, " <>
            "#{map_size(groups)} groups, #{map_size(dogma_attrs)} dogma attrs"
        )

        {:ok, do_seed_from_sde(types, groups, dogma_attrs, type_dogma)}

      {:error, _} = err ->
        err
    end
  end

  @doc "Seed the hardcoded fallback list. Returns `{ok_count, error_count}`."
  def seed_fallback do
    IO.puts("Seeding #{length(@fallback_types)} fallback module types...")

    Enum.reduce(@fallback_types, {0, 0}, fn type, {ok, err} ->
      attrs = Map.put(type, :base_attributes, %{})

      case Ash.create(ModuleType, attrs, upsert?: true, upsert_identity: :unique_eve_type_id) do
        {:ok, module_type} ->
          IO.puts("  ✓ #{module_type.name} (#{module_type.eve_type_id})")
          {ok + 1, err}

        {:error, error} ->
          IO.puts("  ✗ Failed: #{type.name} - #{inspect(error)}")
          {ok, err + 1}
      end
    end)
  end

  defp do_seed_from_sde(types, groups, dogma_attrs, type_dogma) do
    abyssal_types = filter_abyssal_types(types)

    IO.puts("Found #{length(abyssal_types)} abyssal module types in SDE")

    Enum.reduce(abyssal_types, {0, 0}, fn {type_id, type_data}, {ok, err} ->
      case seed_module_type(type_id, type_data, groups, dogma_attrs, type_dogma, types) do
        :ok -> {ok + 1, err}
        :error -> {ok, err + 1}
      end
    end)
  end

  defp filter_abyssal_types(types) do
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
  end

  defp seed_module_type(type_id, type_data, groups, dogma_attrs, type_dogma, all_types) do
    name = get_in(type_data, ["name", "en"])
    group_id = type_data["groupID"]
    group = groups[group_id]
    group_name = get_in(group, ["name", "en"]) || "Unknown"

    category = Map.get(@group_categories, group_id, determine_category(name))
    slot_type = determine_slot_type(group_name, name)
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
        :ok

      {:error, error} ->
        IO.puts("  ✗ Failed: #{name} - #{inspect(error)}")
        :error
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
    reference_type =
      Enum.find(all_types, fn {_id, t} ->
        t["groupID"] == group_id and
          t["published"] == true and
          t["metaGroupID"] == 2 and
          not String.starts_with?(get_in(t, ["name", "en"]) || "", "Abyssal")
      end)

    case reference_type do
      {ref_id, _ref_data} ->
        type_attrs = (type_dogma[ref_id] || %{})["dogmaAttributes"] || []

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
