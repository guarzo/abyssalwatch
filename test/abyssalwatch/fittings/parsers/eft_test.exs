defmodule Abyssalwatch.Fittings.Parsers.EFTTest do
  use ExUnit.Case, async: true

  alias Abyssalwatch.Fittings.Parsers.EFT

  describe "parse/1" do
    test "parses valid EFT format" do
      eft = """
      [Vexor Navy Issue, PvP Fit]

      Damage Control II
      Energized Adaptive Nano Membrane II

      10MN Afterburner II
      Warp Scrambler II

      Heavy Neutron Blaster II
      Heavy Neutron Blaster II

      Medium Trimark Armor Pump I
      """

      assert {:ok, fitting} = EFT.parse(eft)
      assert fitting.ship_type == "Vexor Navy Issue"
      assert fitting.name == "PvP Fit"

      # Check that modules exist with correct names
      low_slot_names = Enum.map(fitting.low_slots, & &1.name)
      assert "Damage Control II" in low_slot_names

      med_slot_names = Enum.map(fitting.med_slots, & &1.name)
      assert "10MN Afterburner II" in med_slot_names

      high_slot_names = Enum.map(fitting.high_slots, & &1.name)
      assert "Heavy Neutron Blaster II" in high_slot_names
    end

    test "parses fitting with only ship name" do
      eft = "[Rifter]"

      assert {:ok, fitting} = EFT.parse(eft)
      assert fitting.ship_type == "Rifter"
      assert fitting.name == "Unnamed Fitting"
    end

    test "handles module quantities (x3 notation)" do
      eft = """
      [Caracal, Missile Boat]

      Ballistic Control System II x3
      """

      assert {:ok, fitting} = EFT.parse(eft)
      # The parser should create one entry with quantity 3
      bcs_entries = Enum.filter(fitting.low_slots, &(&1.name == "Ballistic Control System II"))
      total_quantity = Enum.sum(Enum.map(bcs_entries, & &1.quantity))
      assert total_quantity == 3
    end

    test "returns error for empty input" do
      assert {:error, "EFT text cannot be empty"} = EFT.parse("")
      assert {:error, "EFT text cannot be empty"} = EFT.parse(nil)
    end

    test "returns error for invalid header" do
      assert {:error, "Invalid header format. Expected [Ship Type, Fitting Name]"} =
               EFT.parse("Not a valid header")
    end

    test "identifies drones correctly" do
      eft = """
      [Dominix, Drone Boat]

      Hobgoblin II x5
      Ogre II x5
      """

      assert {:ok, fitting} = EFT.parse(eft)
      drone_names = Enum.map(fitting.drones, & &1.name)
      assert "Hobgoblin II" in drone_names
      assert "Ogre II" in drone_names
    end

    test "identifies rigs correctly" do
      eft = """
      [Stabber, Speed Fit]

      Medium Polycarbon Engine Housing I
      Medium Auxiliary Thrusters I
      """

      assert {:ok, fitting} = EFT.parse(eft)
      rig_names = Enum.map(fitting.rig_slots, & &1.name)
      assert "Medium Polycarbon Engine Housing I" in rig_names
      assert "Medium Auxiliary Thrusters I" in rig_names
    end

    test "trims whitespace from lines" do
      eft = """
      [Drake, PvE]

        Ballistic Control System II
      """

      assert {:ok, fitting} = EFT.parse(eft)
      low_slot_names = Enum.map(fitting.low_slots, & &1.name)
      assert "Ballistic Control System II" in low_slot_names
    end
  end

  describe "to_eft/1" do
    test "converts fitting back to EFT format" do
      fitting = %{
        name: "Test Fit",
        ship_type: "Rifter",
        low_slots: ["Damage Control II"],
        med_slots: ["1MN Afterburner II"],
        high_slots: ["150mm Light Autocannon II"],
        rig_slots: [],
        drones: [],
        cargo: []
      }

      eft = EFT.to_eft(fitting)

      assert String.starts_with?(eft, "[Rifter, Test Fit]")
      assert String.contains?(eft, "Damage Control II")
      assert String.contains?(eft, "1MN Afterburner II")
      assert String.contains?(eft, "150mm Light Autocannon II")
    end

    test "handles empty fitting" do
      fitting = %{
        name: "Empty",
        ship_type: "Rifter",
        low_slots: [],
        med_slots: [],
        high_slots: [],
        rig_slots: [],
        drones: [],
        cargo: []
      }

      eft = EFT.to_eft(fitting)
      assert eft == "[Rifter, Empty]"
    end
  end
end
