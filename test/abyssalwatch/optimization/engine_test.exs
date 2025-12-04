defmodule Abyssalwatch.Optimization.EngineTest do
  use ExUnit.Case, async: true

  alias Abyssalwatch.Optimization.Engine
  alias Abyssalwatch.Optimization.Types.{ModuleCandidate, Constraints, Solution}

  describe "optimize/3" do
    setup do
      candidates = [
        ModuleCandidate.new(%{
          id: "mod1",
          type_id: 47740,
          slot_type: :low,
          name: "Abyssal Damage Control",
          cpu_usage: 30.0,
          power_usage: 1.0,
          calibration_usage: 0.0,
          price: Decimal.new(500_000_000),
          score: 0.85
        }),
        ModuleCandidate.new(%{
          id: "mod2",
          type_id: 47740,
          slot_type: :low,
          name: "Abyssal Damage Control 2",
          cpu_usage: 25.0,
          power_usage: 1.0,
          calibration_usage: 0.0,
          price: Decimal.new(300_000_000),
          score: 0.70
        }),
        ModuleCandidate.new(%{
          id: "mod3",
          type_id: 47820,
          slot_type: :med,
          name: "Abyssal Warp Scrambler",
          cpu_usage: 40.0,
          power_usage: 5.0,
          calibration_usage: 0.0,
          price: Decimal.new(200_000_000),
          score: 0.90
        })
      ]

      constraints =
        Constraints.new(%{
          cpu_capacity: 400.0,
          power_capacity: 1000.0,
          calibration_capacity: 400.0,
          available_slots: %{high: 4, med: 4, low: 4, rig: 3}
        })

      {:ok, candidates: candidates, constraints: constraints}
    end

    test "returns solutions using heuristic solver", %{
      candidates: candidates,
      constraints: constraints
    } do
      assert {:ok, result} = Engine.optimize(candidates, constraints, mode: :heuristic)

      assert is_map(result)
      assert is_list(result.solutions)
      assert result.mode == :heuristic
      assert is_integer(result.solve_time_ms)
      assert result.candidate_count == 3
    end

    test "returns solutions using constraint solver", %{
      candidates: candidates,
      constraints: constraints
    } do
      assert {:ok, result} = Engine.optimize(candidates, constraints, mode: :constraint)

      assert is_map(result)
      assert is_list(result.solutions)
      assert result.mode == :constraint
    end

    test "solutions are ranked by score", %{candidates: candidates, constraints: constraints} do
      {:ok, result} = Engine.optimize(candidates, constraints)

      if length(result.solutions) > 1 do
        scores = Enum.map(result.solutions, & &1.total_score)
        assert scores == Enum.sort(scores, :desc)
      end
    end

    test "solutions have correct rank assigned", %{
      candidates: candidates,
      constraints: constraints
    } do
      {:ok, result} = Engine.optimize(candidates, constraints)

      ranks = Enum.map(result.solutions, & &1.rank)
      expected_ranks = Enum.to_list(1..length(result.solutions))
      assert ranks == expected_ranks
    end

    test "returns error with empty candidates", %{constraints: constraints} do
      assert {:error, "No module candidates provided"} = Engine.optimize([], constraints)
    end

    test "returns error with invalid constraints", %{candidates: candidates} do
      bad_constraints =
        Constraints.new(%{
          cpu_capacity: 0.0,
          power_capacity: 1000.0,
          available_slots: %{high: 4, med: 4, low: 4, rig: 3}
        })

      assert {:error, "CPU capacity must be positive"} =
               Engine.optimize(candidates, bad_constraints)
    end

    test "respects slot constraints", %{candidates: candidates} do
      limited_constraints =
        Constraints.new(%{
          cpu_capacity: 400.0,
          power_capacity: 1000.0,
          calibration_capacity: 400.0,
          available_slots: %{high: 0, med: 1, low: 1, rig: 0}
        })

      {:ok, result} = Engine.optimize(candidates, limited_constraints)

      for solution <- result.solutions do
        usage = solution.resource_usage.slots
        assert usage.low <= 1
        assert usage.med <= 1
        assert usage.high <= 0
        assert usage.rig <= 0
      end
    end

    test "respects CPU constraints", %{candidates: candidates} do
      cpu_limited =
        Constraints.new(%{
          cpu_capacity: 50.0,
          power_capacity: 1000.0,
          calibration_capacity: 400.0,
          available_slots: %{high: 4, med: 4, low: 4, rig: 3}
        })

      {:ok, result} = Engine.optimize(candidates, cpu_limited)

      for solution <- result.solutions do
        assert solution.resource_usage.cpu <= 50.0
      end
    end
  end

  describe "export_to_eft/3" do
    test "generates valid EFT format" do
      modules = [
        ModuleCandidate.new(%{
          id: "1",
          slot_type: :low,
          name: "Damage Control II",
          cpu_usage: 25.0,
          power_usage: 1.0,
          calibration_usage: 0.0,
          price: Decimal.new(1_000_000),
          score: 0.5
        }),
        ModuleCandidate.new(%{
          id: "2",
          slot_type: :med,
          name: "Warp Scrambler II",
          cpu_usage: 30.0,
          power_usage: 5.0,
          calibration_usage: 0.0,
          price: Decimal.new(500_000),
          score: 0.6
        })
      ]

      solution = Solution.build(modules, Abyssalwatch.Optimization.Types.ResourceUsage.new())

      eft = Engine.export_to_eft(solution, "Vexor Navy Issue", "PvP Fit")

      assert String.starts_with?(eft, "[Vexor Navy Issue, PvP Fit]")
      assert String.contains?(eft, "Damage Control II")
      assert String.contains?(eft, "Warp Scrambler II")
    end
  end

  describe "export_to_json/2" do
    test "exports solution to JSON-serializable map" do
      modules = [
        ModuleCandidate.new(%{
          id: "test-id",
          external_id: "ext-123",
          slot_type: :low,
          name: "Test Module",
          cpu_usage: 25.0,
          power_usage: 10.0,
          calibration_usage: 0.0,
          price: Decimal.new(1_000_000_000),
          score: 0.75,
          attributes: %{"damage_modifier" => 1.25}
        })
      ]

      solution = Solution.build(modules, Abyssalwatch.Optimization.Types.ResourceUsage.new())
      solution = %{solution | rank: 1}

      json = Engine.export_to_json(solution)

      assert is_map(json)
      assert json["rank"] == 1
      assert json["total_score"] == 0.75
      assert json["total_price"] == "0"
      assert is_list(json["modules"])
      assert length(json["modules"]) == 1

      [mod] = json["modules"]
      assert mod["name"] == "Test Module"
      assert mod["slot_type"] == "low"
      assert mod["attributes"]["damage_modifier"] == 1.25
    end

    test "can exclude attributes" do
      modules = [
        ModuleCandidate.new(%{
          id: "1",
          slot_type: :low,
          name: "Test",
          cpu_usage: 10.0,
          power_usage: 5.0,
          calibration_usage: 0.0,
          price: Decimal.new(100),
          score: 0.5,
          attributes: %{"secret" => "data"}
        })
      ]

      solution = Solution.build(modules, Abyssalwatch.Optimization.Types.ResourceUsage.new())

      json = Engine.export_to_json(solution, %{include_attributes: false})

      [mod] = json["modules"]
      refute Map.has_key?(mod, "attributes")
    end
  end

  describe "export_solutions_to_json/4" do
    test "exports multiple solutions with metadata" do
      modules = [
        ModuleCandidate.new(%{
          id: "1",
          slot_type: :low,
          name: "Module",
          cpu_usage: 10.0,
          power_usage: 5.0,
          calibration_usage: 0.0,
          price: Decimal.new(100),
          score: 0.5
        })
      ]

      solution = Solution.build(modules, Abyssalwatch.Optimization.Types.ResourceUsage.new())
      solutions = [%{solution | rank: 1}, %{solution | rank: 2}]

      json = Engine.export_solutions_to_json(solutions, "Test Ship", "Test Fit")

      assert json["ship_name"] == "Test Ship"
      assert json["fit_name"] == "Test Fit"
      assert json["solution_count"] == 2
      assert is_binary(json["exported_at"])
      assert length(json["solutions"]) == 2
    end
  end

  describe "prepare_candidates/2" do
    test "converts scored modules to candidates" do
      scored_modules = [
        %{
          module: %{
            id: "abc123",
            type_id: 47740,
            name: "Abyssal Module",
            price: Decimal.new(1_000_000),
            attributes: %{"cpu" => 25.0, "power" => 10.0}
          },
          score: 0.85
        }
      ]

      candidates = Engine.prepare_candidates(scored_modules, :low)

      assert length(candidates) == 1
      [candidate] = candidates
      assert candidate.slot_type == :low
      assert candidate.score == 0.85
      assert candidate.name == "Abyssal Module"
    end
  end

  describe "validate_request/2" do
    test "returns :ok for valid request" do
      candidates = [
        ModuleCandidate.new(%{
          id: "1",
          slot_type: :low,
          name: "Test",
          cpu_usage: 10.0,
          power_usage: 5.0,
          calibration_usage: 0.0,
          price: Decimal.new(100),
          score: 0.5
        })
      ]

      constraints =
        Constraints.new(%{
          cpu_capacity: 400.0,
          power_capacity: 1000.0,
          available_slots: %{low: 4}
        })

      assert :ok = Engine.validate_request(candidates, constraints)
    end

    test "returns error for empty candidates" do
      constraints =
        Constraints.new(%{
          cpu_capacity: 400.0,
          power_capacity: 1000.0,
          available_slots: %{low: 4}
        })

      assert {:error, _} = Engine.validate_request([], constraints)
    end

    test "returns error for zero CPU capacity" do
      candidates = [
        ModuleCandidate.new(%{
          id: "1",
          slot_type: :low,
          name: "Test",
          cpu_usage: 10.0,
          power_usage: 5.0,
          calibration_usage: 0.0,
          price: Decimal.new(100),
          score: 0.5
        })
      ]

      constraints =
        Constraints.new(%{
          cpu_capacity: 0.0,
          power_capacity: 1000.0,
          available_slots: %{low: 4}
        })

      assert {:error, "CPU capacity must be positive"} =
               Engine.validate_request(candidates, constraints)
    end
  end
end
