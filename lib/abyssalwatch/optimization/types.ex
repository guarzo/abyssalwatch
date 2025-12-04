defmodule Abyssalwatch.Optimization.Types do
  @moduledoc """
  Type definitions for the optimization engine.

  Defines the core data structures used throughout the ship fitting
  optimization process: module candidates, constraints, and solutions.
  """

  defmodule ModuleCandidate do
    @moduledoc """
    Represents a candidate abyssal module for optimization.

    Contains all the information needed to evaluate a module's fit
    within a ship's constraints and objectives.
    """

    @type slot_type :: :high | :med | :low | :rig

    @type t :: %__MODULE__{
            id: String.t(),
            external_id: String.t() | nil,
            type_id: integer(),
            slot_type: slot_type(),
            name: String.t(),
            cpu_usage: float(),
            power_usage: float(),
            calibration_usage: float(),
            price: Decimal.t(),
            score: float(),
            efficiency: float(),
            attributes: map()
          }

    defstruct [
      :id,
      :external_id,
      :type_id,
      :slot_type,
      :name,
      :cpu_usage,
      :power_usage,
      :calibration_usage,
      :price,
      :score,
      :efficiency,
      :attributes
    ]

    @doc """
    Creates a new ModuleCandidate from a module data map.
    """
    def new(attrs) do
      price = normalize_price(attrs[:price] || attrs["price"])
      score = attrs[:score] || attrs["score"] || 0.0

      %__MODULE__{
        id: attrs[:id] || attrs["id"] || generate_id(),
        external_id: attrs[:external_id] || attrs["external_id"],
        type_id: attrs[:type_id] || attrs["type_id"],
        slot_type: normalize_slot_type(attrs[:slot_type] || attrs["slot_type"]),
        name: attrs[:name] || attrs["name"] || "Unknown",
        cpu_usage: normalize_float(attrs[:cpu_usage] || attrs["cpu_usage"] || 0),
        power_usage: normalize_float(attrs[:power_usage] || attrs["power_usage"] || 0),
        calibration_usage:
          normalize_float(attrs[:calibration_usage] || attrs["calibration_usage"] || 0),
        price: price,
        score: score,
        efficiency: calculate_efficiency(score, price),
        attributes: attrs[:attributes] || attrs["attributes"] || %{}
      }
    end

    @doc """
    Creates ModuleCandidates from a list of scored modules.
    """
    def from_scored_modules(scored_modules, slot_type) do
      Enum.map(scored_modules, fn %{module: module, score: score} ->
        new(%{
          id: module[:id] || module[:external_id] || generate_id(),
          external_id: module[:external_id],
          type_id: module[:type_id],
          slot_type: slot_type,
          name: module[:name],
          cpu_usage: get_attribute(module, "cpu"),
          power_usage: get_attribute(module, "power") || get_attribute(module, "powergrid"),
          calibration_usage: get_attribute(module, "calibration"),
          price: module[:price],
          score: score,
          attributes: module[:attributes] || %{}
        })
      end)
    end

    defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    defp normalize_price(%Decimal{} = price), do: price
    defp normalize_price(price) when is_number(price), do: Decimal.new(round(price))
    defp normalize_price(_), do: Decimal.new(0)

    defp normalize_float(value) when is_float(value), do: value
    defp normalize_float(value) when is_integer(value), do: value / 1.0
    defp normalize_float(%Decimal{} = value), do: Decimal.to_float(value)

    defp normalize_float(value) when is_binary(value) do
      case Float.parse(value) do
        {f, _} -> f
        :error -> 0.0
      end
    end

    defp normalize_float(_), do: 0.0

    defp normalize_slot_type(:high), do: :high
    defp normalize_slot_type(:med), do: :med
    defp normalize_slot_type(:low), do: :low
    defp normalize_slot_type(:rig), do: :rig
    defp normalize_slot_type("high"), do: :high
    defp normalize_slot_type("med"), do: :med
    defp normalize_slot_type("low"), do: :low
    defp normalize_slot_type("rig"), do: :rig
    defp normalize_slot_type(_), do: :low

    defp calculate_efficiency(_score, %Decimal{} = price) do
      price_float = Decimal.to_float(price)
      if price_float > 0, do: 1.0 / price_float * 1_000_000_000, else: 0.0
    end

    defp calculate_efficiency(score, _), do: score

    defp get_attribute(module, key) do
      attrs = module[:attributes] || %{}
      attrs[key] || attrs[String.to_atom(key)] || 0.0
    end
  end

  defmodule Constraints do
    @moduledoc """
    Ship fitting constraints for optimization.

    Defines the resource capacities and slot counts that must be
    respected when building an optimized fitting.
    """

    @type t :: %__MODULE__{
            cpu_capacity: float(),
            power_capacity: float(),
            calibration_capacity: float(),
            available_slots: %{
              high: non_neg_integer(),
              med: non_neg_integer(),
              low: non_neg_integer(),
              rig: non_neg_integer()
            },
            max_price: Decimal.t() | nil
          }

    defstruct [
      :cpu_capacity,
      :power_capacity,
      :calibration_capacity,
      :available_slots,
      :max_price
    ]

    @doc """
    Creates new Constraints with sensible defaults.
    """
    def new(attrs \\ %{}) do
      %__MODULE__{
        cpu_capacity: attrs[:cpu_capacity] || attrs["cpu_capacity"] || 0.0,
        power_capacity: attrs[:power_capacity] || attrs["power_capacity"] || 0.0,
        calibration_capacity:
          attrs[:calibration_capacity] || attrs["calibration_capacity"] || 400.0,
        available_slots: normalize_slots(attrs[:available_slots] || attrs["available_slots"]),
        max_price: normalize_max_price(attrs[:max_price] || attrs["max_price"])
      }
    end

    defp normalize_slots(nil), do: %{high: 0, med: 0, low: 0, rig: 0}

    defp normalize_slots(slots) when is_map(slots) do
      %{
        high: slots[:high] || slots["high"] || 0,
        med: slots[:med] || slots["med"] || 0,
        low: slots[:low] || slots["low"] || 0,
        rig: slots[:rig] || slots["rig"] || 0
      }
    end

    defp normalize_max_price(nil), do: nil
    defp normalize_max_price(%Decimal{} = price), do: price
    defp normalize_max_price(price) when is_number(price), do: Decimal.new(round(price))
    defp normalize_max_price(_), do: nil

    @doc """
    Validates that constraints are properly configured.
    """
    def validate(%__MODULE__{} = constraints) do
      cond do
        constraints.cpu_capacity <= 0 ->
          {:error, "CPU capacity must be positive"}

        constraints.power_capacity <= 0 ->
          {:error, "Power capacity must be positive"}

        all_slots_zero?(constraints.available_slots) ->
          {:error, "At least one slot type must be available"}

        true ->
          :ok
      end
    end

    defp all_slots_zero?(slots) do
      Enum.all?(Map.values(slots), &(&1 == 0))
    end
  end

  defmodule ResourceUsage do
    @moduledoc """
    Tracks resource consumption for a solution.
    """

    @type t :: %__MODULE__{
            cpu: float(),
            power: float(),
            calibration: float(),
            slots: %{
              high: non_neg_integer(),
              med: non_neg_integer(),
              low: non_neg_integer(),
              rig: non_neg_integer()
            },
            price: Decimal.t()
          }

    defstruct cpu: 0.0,
              power: 0.0,
              calibration: 0.0,
              slots: %{high: 0, med: 0, low: 0, rig: 0},
              price: Decimal.new(0)

    @doc """
    Creates a new empty ResourceUsage.
    """
    def new do
      %__MODULE__{
        cpu: 0.0,
        power: 0.0,
        calibration: 0.0,
        slots: %{high: 0, med: 0, low: 0, rig: 0},
        price: Decimal.new(0)
      }
    end

    @doc """
    Adds a module's resource usage to the current totals.
    """
    def add(%__MODULE__{} = usage, %ModuleCandidate{} = candidate) do
      %__MODULE__{
        cpu: usage.cpu + candidate.cpu_usage,
        power: usage.power + candidate.power_usage,
        calibration: usage.calibration + candidate.calibration_usage,
        slots: Map.update!(usage.slots, candidate.slot_type, &(&1 + 1)),
        price: Decimal.add(usage.price, candidate.price)
      }
    end

    @doc """
    Checks if adding a module would exceed constraints.
    """
    def can_add?(
          %__MODULE__{} = usage,
          %ModuleCandidate{} = candidate,
          %Constraints{} = constraints
        ) do
      new_cpu = usage.cpu + candidate.cpu_usage
      new_power = usage.power + candidate.power_usage
      new_calibration = usage.calibration + candidate.calibration_usage
      new_slot_count = Map.get(usage.slots, candidate.slot_type, 0) + 1
      new_price = Decimal.add(usage.price, candidate.price)

      new_cpu <= constraints.cpu_capacity and
        new_power <= constraints.power_capacity and
        new_calibration <= constraints.calibration_capacity and
        new_slot_count <= Map.get(constraints.available_slots, candidate.slot_type, 0) and
        price_within_budget?(new_price, constraints.max_price)
    end

    defp price_within_budget?(_price, nil), do: true

    defp price_within_budget?(price, max_price) do
      Decimal.compare(price, max_price) != :gt
    end
  end

  defmodule Solution do
    @moduledoc """
    Represents a complete optimization solution.

    A solution contains the selected modules and aggregate metrics
    about the fitting's performance and resource usage.
    """

    @type t :: %__MODULE__{
            id: String.t(),
            rank: non_neg_integer(),
            modules: [ModuleCandidate.t()],
            total_score: float(),
            total_price: Decimal.t(),
            efficiency: float(),
            resource_usage: ResourceUsage.t(),
            score_breakdown: map()
          }

    defstruct [
      :id,
      :rank,
      :modules,
      :total_score,
      :total_price,
      :efficiency,
      :resource_usage,
      :score_breakdown
    ]

    @doc """
    Builds a solution from a list of selected modules and resource usage.
    """
    def build(modules, %ResourceUsage{} = usage) when is_list(modules) do
      total_score = Enum.sum(Enum.map(modules, & &1.score))
      total_price = usage.price
      efficiency = calculate_efficiency(total_score, total_price)

      %__MODULE__{
        id: generate_id(),
        rank: 0,
        modules: modules,
        total_score: Float.round(total_score, 4),
        total_price: total_price,
        efficiency: Float.round(efficiency, 6),
        resource_usage: usage,
        score_breakdown: build_breakdown(modules)
      }
    end

    @doc """
    Compares two solutions by total score.
    """
    def compare(%__MODULE__{total_score: a}, %__MODULE__{total_score: b}) do
      cond do
        a > b -> :gt
        a < b -> :lt
        true -> :eq
      end
    end

    defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    defp calculate_efficiency(_score, %Decimal{} = price) do
      price_float = Decimal.to_float(price)
      if price_float > 0, do: 1.0 / price_float * 1_000_000_000, else: 0.0
    end

    defp build_breakdown(modules) do
      by_slot =
        modules
        |> Enum.group_by(& &1.slot_type)
        |> Enum.map(fn {slot, mods} ->
          {slot,
           %{
             count: length(mods),
             total_score: Enum.sum(Enum.map(mods, & &1.score)),
             total_price: Enum.reduce(mods, Decimal.new(0), &Decimal.add(&1.price, &2))
           }}
        end)
        |> Map.new()

      %{
        by_slot: by_slot,
        module_count: length(modules)
      }
    end
  end
end
