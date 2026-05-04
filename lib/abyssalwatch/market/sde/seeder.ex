defmodule Abyssalwatch.Market.SDE.Seeder do
  @moduledoc """
  Seeds `Abyssalwatch.Market.ModuleType` rows from a SDE zip via streaming.

  Public entry points:

    * `seed_from_zip/1` — preferred, opens the zip with `Loader.with_archive`
      and runs the streaming three-pass pipeline below.
    * `seed_fallback/0` — hardcoded list, used when no SDE is available.

  Both upsert by `:unique_eve_type_id` so they are safe to re-run.

  Returns `{:ok, {ok_count, error_count}}`.
  """

  require Logger

  alias Abyssalwatch.Market.ModuleType
  alias Abyssalwatch.Market.SDE.Loader

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
    52 => "Tackle", 65 => "Tackle",
    59 => "Damage", 205 => "Damage", 302 => "Damage",
    367 => "Damage", 1988 => "Damage",
    60 => "Tank", 515 => "Capital",
    46 => "Propulsion", 58 => "Propulsion",
    774 => "Shield", 77 => "Shield",
    62 => "Armor", 98 => "Armor",
    326 => "Armor", 1150 => "Armor"
  }

  @fallback_types [
    %{eve_type_id: 47702, name: "Abyssal Stasis Webifier", category: "Tackle", slot_type: :med},
    %{eve_type_id: 47732, name: "Abyssal Warp Scrambler", category: "Tackle", slot_type: :med},
    %{eve_type_id: 47736, name: "Abyssal Warp Disruptor", category: "Tackle", slot_type: :med},
    %{eve_type_id: 49722, name: "Abyssal Magnetic Field Stabilizer", category: "Damage", slot_type: :low},
    %{eve_type_id: 49726, name: "Abyssal Heat Sink", category: "Damage", slot_type: :low},
    %{eve_type_id: 49730, name: "Abyssal Gyrostabilizer", category: "Damage", slot_type: :low},
    %{eve_type_id: 49734, name: "Abyssal Entropic Radiation Sink", category: "Damage", slot_type: :low},
    %{eve_type_id: 49738, name: "Abyssal Ballistic Control System", category: "Damage", slot_type: :low},
    %{eve_type_id: 52227, name: "Abyssal Damage Control", category: "Tank", slot_type: :low},
    %{eve_type_id: 52230, name: "Abyssal Assault Damage Control", category: "Tank", slot_type: :low},
    %{eve_type_id: 56313, name: "Abyssal Siege Module", category: "Capital", slot_type: :high}
  ]

  @doc """
  Seed from an SDE zip on disk. Opens the zip, runs the three-pass streaming
  pipeline, returns `{:ok, {ok_count, err_count}}`.
  """
  def seed_from_zip(zip_path) do
    Loader.with_archive(zip_path, fn handle ->
      {:ok, do_streaming_seed(handle)}
    end)
  end

  @doc "Seed the hardcoded fallback list."
  def seed_fallback do
    Logger.info("Seeding #{length(@fallback_types)} fallback module types")

    counts =
      Enum.reduce(@fallback_types, {0, 0}, fn type, {ok, err} ->
        attrs = Map.put(type, :base_attributes, %{})

        case Ash.create(ModuleType, attrs, upsert?: true, upsert_identity: :unique_eve_type_id) do
          {:ok, _} -> {ok + 1, err}
          {:error, error} ->
            Logger.warning("fallback seed failed for #{type.name}: #{inspect(error)}")
            {ok, err + 1}
        end
      end)

    {:ok, counts}
  end

  defp do_streaming_seed(handle) do
    {abyssal_types, ref_types_by_group} = pass1_collect_types(handle)

    Logger.info(
      "SDE: found #{map_size(abyssal_types)} abyssal types, " <>
        "#{map_size(ref_types_by_group)} reference types"
    )

    groups = pass2_collect_groups(handle, abyssal_types, ref_types_by_group)
    {type_dogma, dogma_attrs} = pass3_collect_dogma(handle, ref_types_by_group)

    Enum.reduce(abyssal_types, {0, 0}, fn {type_id, type_data}, {ok, err} ->
      case seed_module_type(type_id, type_data, groups, dogma_attrs, type_dogma,
             ref_types_by_group) do
        :ok -> {ok + 1, err}
        :error -> {ok, err + 1}
      end
    end)
  end

  defp pass1_collect_types(handle) do
    handle
    |> Loader.stream_entry("types.jsonl")
    |> Enum.reduce({%{}, %{}}, fn t, {abyssal, refs} ->
      published? = t["published"] == true
      name = get_in(t, ["name", "en"]) || ""
      type_id = t["_key"]
      group_id = t["groupID"]

      cond do
        published? and abyssal_name?(name) and not excluded_name?(name) ->
          {Map.put(abyssal, type_id, t), refs}

        published? and t["metaGroupID"] == 2 and not String.starts_with?(name, "Abyssal") ->
          {abyssal, Map.put_new(refs, group_id, type_id)}

        true ->
          {abyssal, refs}
      end
    end)
  end

  defp pass2_collect_groups(handle, abyssal_types, ref_types_by_group) do
    needed_group_ids =
      MapSet.new(
        Enum.map(abyssal_types, fn {_id, t} -> t["groupID"] end) ++
          Map.keys(ref_types_by_group)
      )

    handle
    |> Loader.stream_entry("groups.jsonl")
    |> Stream.filter(&MapSet.member?(needed_group_ids, &1["_key"]))
    |> Enum.reduce(%{}, fn g, acc -> Map.put(acc, g["_key"], g) end)
  end

  defp pass3_collect_dogma(handle, ref_types_by_group) do
    needed_ref_ids = MapSet.new(Map.values(ref_types_by_group))

    type_dogma =
      handle
      |> Loader.stream_entry("typeDogma.jsonl")
      |> Stream.filter(&MapSet.member?(needed_ref_ids, &1["_key"]))
      |> Enum.reduce(%{}, fn td, acc -> Map.put(acc, td["_key"], td) end)

    needed_attr_ids =
      type_dogma
      |> Map.values()
      |> Enum.flat_map(fn td -> td["dogmaAttributes"] || [] end)
      |> Enum.map(& &1["attributeID"])
      |> Enum.filter(&Map.has_key?(@key_attributes, &1))
      |> MapSet.new()

    dogma_attrs =
      handle
      |> Loader.stream_entry("dogmaAttributes.jsonl")
      |> Stream.filter(&MapSet.member?(needed_attr_ids, &1["_key"]))
      |> Enum.reduce(%{}, fn a, acc -> Map.put(acc, a["_key"], a) end)

    {type_dogma, dogma_attrs}
  end

  defp abyssal_name?(name), do: String.starts_with?(name, "Abyssal ")

  defp excluded_name?(name) do
    String.contains?(name, "Blueprint") or
      String.contains?(name, "Mining Crystal") or
      String.contains?(name, "Mining Laser") or
      String.contains?(name, "Strip Miner") or
      String.contains?(name, "Deep Core Miner") or
      String.contains?(name, "Corruption")
  end

  defp seed_module_type(type_id, type_data, groups, dogma_attrs, type_dogma, ref_types_by_group) do
    name = get_in(type_data, ["name", "en"])
    group_id = type_data["groupID"]
    group = groups[group_id]
    group_name = get_in(group, ["name", "en"]) || "Unknown"

    category = Map.get(@group_categories, group_id, determine_category(name))
    slot_type = determine_slot_type(group_name, name)
    base_attributes = base_attributes_for(group_id, dogma_attrs, type_dogma, ref_types_by_group)

    attrs = %{
      eve_type_id: type_id,
      name: name,
      category: category,
      slot_type: slot_type,
      base_attributes: base_attributes
    }

    case Ash.create(ModuleType, attrs, upsert?: true, upsert_identity: :unique_eve_type_id) do
      {:ok, _} -> :ok
      {:error, error} ->
        Logger.warning("SDE upsert failed for #{name} (#{type_id}): #{inspect(error)}")
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

  defp base_attributes_for(group_id, dogma_attrs, type_dogma, ref_types_by_group) do
    case Map.get(ref_types_by_group, group_id) do
      nil -> %{}

      ref_id ->
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
    end
  end
end
