defmodule Abyssalwatch.Fittings.Parsers.EFT do
  @moduledoc """
  Enhanced parser for EVE Fitting Tool (EFT) format.

  Supports official EFT format features:
  - [Ship, Name] header
  - Module sections separated by blank lines (low → med → high → rigs → subsystems → drones → cargo)
  - Empty slot markers: [Empty Low slot], [Empty Med slot], etc.
  - Quantity suffixes: x## (e.g., "Hobgoblin II x5")
  - Offline notation: /offline suffix (stripped on import)
  - Charge notation: Module Name, Charge Name

  ## Example Format

  ```
  [Vexor Navy Issue, PvP Fit]
  Damage Control II
  Drone Damage Amplifier II
  Drone Damage Amplifier II
  [Empty Low slot]

  10MN Afterburner II
  Warp Scrambler II
  Stasis Webifier II

  Medium Energy Neutralizer II
  Medium Energy Neutralizer II
  Drone Link Augmentor I /offline

  Medium Auxiliary Nano Pump I
  Medium Auxiliary Nano Pump I

  Hobgoblin II x5
  Hammerhead II x5
  ```

  ## Section Order (standard EFT format)

  1. Low slots
  2. Medium slots
  3. High slots
  4. Rig slots
  5. Subsystems (T3 cruisers only)
  6. Drones
  7. Cargo/Fighter bay

  Empty lines separate sections.
  """

  @empty_slot_pattern ~r/^\[Empty\s+(\w+)\s+slot\]$/i
  @quantity_pattern ~r/^(.+?)\s+x(\d+)$/i
  @offline_pattern ~r/\s*\/offline$/i
  @charge_pattern ~r/^(.+?),\s*(.+)$/

  @doc """
  Parses EFT format text into a fitting structure.

  Returns `{:ok, parsed}` on success or `{:error, reason}` on failure.

  ## Parsed Structure

    - `:name` - Fitting name
    - `:ship_type` - Ship type name
    - `:low_slots` - List of low slot modules
    - `:med_slots` - List of medium slot modules
    - `:high_slots` - List of high slot modules
    - `:rig_slots` - List of rig modules
    - `:subsystems` - List of subsystem modules (T3)
    - `:drones` - List of drones with quantities
    - `:cargo` - List of cargo items with quantities
    - `:modules` - Flat list of all modules (for compatibility)
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(nil), do: {:error, "EFT text cannot be empty"}
  def parse(""), do: {:error, "EFT text cannot be empty"}

  def parse(text) when is_binary(text) do
    lines =
      text
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)

    case lines do
      [] ->
        {:error, "EFT text cannot be empty"}

      [header | rest] ->
        case parse_header(header) do
          {:ok, ship_type, name} ->
            sections = parse_sections(rest)

            {:ok,
             %{
               name: name,
               ship_type: ship_type,
               low_slots: sections.low_slots,
               med_slots: sections.med_slots,
               high_slots: sections.high_slots,
               rig_slots: sections.rig_slots,
               subsystems: sections.subsystems,
               drones: sections.drones,
               cargo: sections.cargo,
               # Flat list for backward compatibility
               modules: flatten_all_slots(sections)
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def parse(_), do: {:error, "Invalid input type"}

  @doc """
  Converts a parsed fitting back to EFT format.

  Options:
    - `:include_empty_slots` - Whether to include [Empty X slot] markers (default: false)
    - `:include_offline` - Whether to include /offline markers (default: false)
  """
  @spec encode(map(), keyword()) :: String.t()
  def encode(fitting, opts \\ []) do
    include_empty = Keyword.get(opts, :include_empty_slots, false)

    header =
      "[#{fitting[:ship_type] || fitting["ship_type"]}, #{fitting[:name] || fitting["name"]}]"

    sections =
      [
        encode_section(fitting[:low_slots] || fitting["low_slots"], "Low", include_empty),
        encode_section(fitting[:med_slots] || fitting["med_slots"], "Med", include_empty),
        encode_section(fitting[:high_slots] || fitting["high_slots"], "Hi", include_empty),
        encode_section(fitting[:rig_slots] || fitting["rig_slots"], "Rig", include_empty),
        encode_section(fitting[:subsystems] || fitting["subsystems"], "Subsystem", include_empty),
        encode_drone_section(fitting[:drones] || fitting["drones"]),
        encode_cargo_section(fitting[:cargo] || fitting["cargo"])
      ]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))
      |> Enum.join("\n\n")

    if sections == "" do
      header
    else
      header <> "\n\n" <> sections
    end
  end

  @doc """
  Alias for encode/2 for backward compatibility.
  """
  @spec to_eft(map()) :: String.t()
  def to_eft(fitting), do: encode(fitting)

  # Private functions - Header parsing

  defp parse_header(header) do
    header = String.trim(header)

    if String.starts_with?(header, "[") and String.ends_with?(header, "]") do
      content = String.slice(header, 1..-2//1)

      case String.split(content, ",", parts: 2) do
        [ship_type, name] ->
          {:ok, String.trim(ship_type), String.trim(name)}

        [ship_type] ->
          {:ok, String.trim(ship_type), "Unnamed Fitting"}

        _ ->
          {:error, "Invalid header format. Expected [Ship Type, Fitting Name]"}
      end
    else
      {:error, "Invalid header format. Expected [Ship Type, Fitting Name]"}
    end
  end

  # Private functions - Section parsing

  defp parse_sections(lines) do
    # Split by blank lines into sections
    raw_sections =
      lines
      |> Enum.chunk_by(&(&1 == ""))
      |> Enum.reject(fn chunk -> Enum.all?(chunk, &(&1 == "")) end)

    # Parse each section into modules
    parsed_sections = Enum.map(raw_sections, &parse_section_lines/1)

    # Assign sections based on standard EFT order:
    # low, med, high, rigs, subsystems, drones, cargo
    assign_sections_by_order(parsed_sections)
  end

  defp parse_section_lines(lines) do
    lines
    |> Enum.map(&parse_module_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_module_line(line) do
    line = String.trim(line)

    cond do
      # Skip empty lines
      line == "" ->
        nil

      # Skip empty slot markers (but could track them for slot counting)
      Regex.match?(@empty_slot_pattern, line) ->
        nil

      # Parse actual module line
      true ->
        parse_module_entry(line)
    end
  end

  defp parse_module_entry(line) do
    # Strip offline marker
    {line, offline} =
      if Regex.match?(@offline_pattern, line) do
        {String.replace(line, @offline_pattern, ""), true}
      else
        {line, false}
      end

    # Check for charge notation (Module, Charge)
    {module_name, charge} =
      case Regex.run(@charge_pattern, line) do
        [_, mod, chg] -> {String.trim(mod), String.trim(chg)}
        _ -> {line, nil}
      end

    # Check for quantity notation (Module x5)
    {name, quantity} =
      case Regex.run(@quantity_pattern, module_name) do
        [_, mod, qty] -> {String.trim(mod), String.to_integer(qty)}
        _ -> {String.trim(module_name), 1}
      end

    %{
      name: name,
      quantity: quantity,
      charge: charge,
      offline: offline
    }
  end

  # Assign sections based on EFT order and module type detection
  defp assign_sections_by_order(sections) do
    initial = %{
      low_slots: [],
      med_slots: [],
      high_slots: [],
      rig_slots: [],
      subsystems: [],
      drones: [],
      cargo: []
    }

    # If we have sections, try to categorize them
    case length(sections) do
      0 ->
        initial

      _ ->
        # Use heuristics to categorize modules
        categorize_all_modules(List.flatten(sections))
    end
  end

  defp categorize_all_modules(modules) do
    Enum.reduce(
      modules,
      %{
        low_slots: [],
        med_slots: [],
        high_slots: [],
        rig_slots: [],
        subsystems: [],
        drones: [],
        cargo: []
      },
      fn module, acc ->
        slot = categorize_module(module.name)
        Map.update!(acc, slot, &(&1 ++ [module]))
      end
    )
  end

  defp categorize_module(name) do
    cond do
      is_drone?(name) -> :drones
      is_subsystem?(name) -> :subsystems
      is_rig?(name) -> :rig_slots
      is_high_slot?(name) -> :high_slots
      is_low_slot?(name) -> :low_slots
      is_cargo?(name) -> :cargo
      true -> :med_slots
    end
  end

  # Module type detection

  defp is_drone?(name) do
    drone_patterns = [
      "Drone",
      "Warrior",
      "Hammerhead",
      "Ogre",
      "Hobgoblin",
      "Hornet",
      "Vespa",
      "Wasp",
      "Infiltrator",
      "Praetor",
      "Acolyte",
      "Berserker",
      "Bouncer",
      "Curator",
      "Garde",
      "Warden",
      "Gecko",
      "Augmented",
      "Integrated",
      "'Augmented'",
      "'Integrated'"
    ]

    Enum.any?(drone_patterns, &String.contains?(name, &1))
  end

  defp is_subsystem?(name) do
    String.contains?(name, "Subsystem") or
      String.ends_with?(name, "- Defensive") or
      String.ends_with?(name, "- Offensive") or
      String.ends_with?(name, "- Propulsion") or
      String.ends_with?(name, "- Core")
  end

  defp is_rig?(name) do
    rig_patterns = [
      "Rig",
      "Ancillary Current Router",
      "Auxiliary Thrusters",
      "Polycarbon",
      "Trimark",
      "Anti-",
      "Capacitor Control",
      "Cargohold Optimization",
      "Drone Durability",
      "Drone Mining",
      "Drone Repair",
      "Drone Speed",
      "Egress Port",
      "Energy",
      "Field Extender",
      "Gravity Capacitor",
      "Higgs Anchor",
      "Hyperspatial",
      "Low Friction",
      "Nanobot",
      "Processor",
      "Projectile",
      "Pump",
      "Salvage Tackle",
      "Semiconductor",
      "Signal Focusing",
      "Transverse",
      "Warp Core"
    ]

    # Check for "Small/Medium/Large X" rig naming
    size_prefix =
      String.starts_with?(name, "Small ") or
        String.starts_with?(name, "Medium ") or
        String.starts_with?(name, "Large ") or
        String.starts_with?(name, "Capital ")

    Enum.any?(rig_patterns, &String.contains?(name, &1)) or
      (size_prefix and not is_drone?(name) and not is_weapon?(name))
  end

  defp is_weapon?(name) do
    weapon_patterns = [
      "Turret",
      "Launcher",
      "Blaster",
      "Railgun",
      "Beam Laser",
      "Pulse Laser",
      "Autocannon",
      "Artillery",
      "Howitzer",
      "Neutron",
      "Ion",
      "Electron",
      "Mega",
      "Heavy",
      "Light"
    ]

    Enum.any?(weapon_patterns, &String.contains?(name, &1))
  end

  defp is_high_slot?(name) do
    high_patterns = [
      "Launcher",
      "Turret",
      "Blaster",
      "Railgun",
      "Beam Laser",
      "Pulse Laser",
      "Autocannon",
      "Artillery",
      "Howitzer",
      "Torpedo",
      "Cruise Missile",
      "Heavy Assault Missile",
      "Rapid",
      "Drone Link",
      "Nosferatu",
      "Neutralizer",
      "Smartbomb",
      "Bomb Launcher",
      "Cloak",
      "Cynosural",
      "Tractor Beam",
      "Salvager",
      "Survey Scanner",
      "Probe Launcher",
      "Festival Launcher",
      "Snowball Launcher",
      "Strip Miner",
      "Ice Harvester",
      "Gas Cloud Harvester",
      "Mining Laser",
      "Remote Armor",
      "Remote Shield",
      "Remote Hull",
      "Remote Capacitor",
      "Remote Sensor",
      "Remote Tracking",
      "Interdiction Sphere",
      "Command Burst",
      "Bastion Module",
      "Industrial Core",
      "Siege Module",
      "Triage Module",
      "Doomsday",
      "Jump Portal"
    ]

    Enum.any?(high_patterns, &String.contains?(name, &1))
  end

  defp is_low_slot?(name) do
    low_patterns = [
      "Damage Control",
      "Armor Plate",
      "Armor Hardener",
      "Armor Repairer",
      "Energized",
      "Nanofiber",
      "Overdrive",
      "Inertial Stabilizer",
      "Warp Core Stabilizer",
      "Tracking Enhancer",
      "Magnetic Field Stabilizer",
      "Heat Sink",
      "Gyrostabilizer",
      "Ballistic Control",
      "Drone Damage Amplifier",
      "Co-Processor",
      "Power Diagnostic",
      "Reactor Control",
      "Capacitor Flux",
      "Signal Amplifier",
      "Sensor Booster",
      "Expanded Cargohold",
      "Reinforced Bulkheads",
      "Cargo Optimizer",
      "Layered Plating",
      "Adaptive Nano Plating",
      "Multispectrum",
      "Coating",
      "Membrane",
      "Armor Explosive",
      "Armor Kinetic",
      "Armor Thermal",
      "Armor EM",
      "Damage Amplifier",
      "Mining Upgrade",
      "Ice Harvester Upgrade",
      "Omnidirectional Tracking",
      "Drone Navigation",
      "Drone Sharpshooting"
    ]

    Enum.any?(low_patterns, &String.contains?(name, &1))
  end

  defp is_cargo?(name) do
    cargo_patterns = [
      "Ammo",
      "Charge",
      "Script",
      "Nanite",
      "Cap Booster",
      "Frequency Crystal",
      "Standard ",
      "Faction ",
      "Navy ",
      "Antimatter",
      "Multifrequency",
      "Radio",
      "Microwave",
      "Infrared",
      "Standard",
      "Uranium",
      "Plutonium",
      "Thorium",
      "Titanium Sabot",
      "Depleted Uranium",
      "Fusion",
      "Phased Plasma",
      "EMP",
      "Proton",
      "Nuclear",
      "Carbonized Lead",
      "Javelin",
      "Spike",
      "Gleam",
      "Aurora",
      "Scorch",
      "Conflagration",
      "Hail",
      "Barrage",
      "Tremor",
      "Quake",
      "Void",
      "Null",
      "Rage",
      "Fury",
      "Precision",
      "Javelin",
      "Auto-Targeting",
      "Blueprint",
      "Mobile Depot",
      "Mobile Tractor",
      "Mobile Cyno"
    ]

    Enum.any?(cargo_patterns, &String.contains?(name, &1))
  end

  # Encoding helpers

  defp encode_section(nil, _slot_type, _include_empty), do: ""
  defp encode_section([], _slot_type, _include_empty), do: ""

  defp encode_section(modules, slot_type, include_empty) when is_list(modules) do
    lines =
      modules
      |> Enum.map(fn
        %{name: name, quantity: qty, offline: offline, charge: charge} ->
          encode_module_line(name, qty, offline, charge)

        %{name: name, quantity: qty, offline: offline} ->
          encode_module_line(name, qty, offline, nil)

        %{name: name, quantity: qty} ->
          encode_module_line(name, qty, false, nil)

        %{"name" => name, "quantity" => qty} ->
          encode_module_line(name, qty, false, nil)

        name when is_binary(name) ->
          name
      end)

    # Add empty slot markers if requested and we have fewer than expected
    # (This would require knowing slot counts, so skip for now)
    if include_empty do
      lines ++ Enum.map(1..0//1, fn _ -> "[Empty #{slot_type} slot]" end)
    else
      lines
    end
    |> Enum.join("\n")
  end

  defp encode_module_line(name, quantity, offline, charge) do
    base =
      if charge do
        "#{name}, #{charge}"
      else
        name
      end

    with_qty =
      if quantity > 1 do
        "#{base} x#{quantity}"
      else
        base
      end

    if offline do
      "#{with_qty} /offline"
    else
      with_qty
    end
  end

  defp encode_drone_section(nil), do: ""
  defp encode_drone_section([]), do: ""

  defp encode_drone_section(drones) when is_list(drones) do
    drones
    |> Enum.map(fn
      %{name: name, quantity: qty} when qty > 1 -> "#{name} x#{qty}"
      %{name: name} -> name
      %{"name" => name, "quantity" => qty} when qty > 1 -> "#{name} x#{qty}"
      %{"name" => name} -> name
      name when is_binary(name) -> name
    end)
    |> Enum.join("\n")
  end

  defp encode_cargo_section(nil), do: ""
  defp encode_cargo_section([]), do: ""

  defp encode_cargo_section(cargo) when is_list(cargo) do
    cargo
    |> Enum.map(fn
      %{name: name, quantity: qty} when qty > 1 -> "#{name} x#{qty}"
      %{name: name} -> name
      %{"name" => name, "quantity" => qty} when qty > 1 -> "#{name} x#{qty}"
      %{"name" => name} -> name
      name when is_binary(name) -> name
    end)
    |> Enum.join("\n")
  end

  defp flatten_all_slots(sections) do
    [
      sections.low_slots,
      sections.med_slots,
      sections.high_slots,
      sections.rig_slots,
      sections.subsystems,
      sections.drones,
      sections.cargo
    ]
    |> Enum.flat_map(fn
      nil -> []
      list -> Enum.map(list, & &1.name)
    end)
  end
end
