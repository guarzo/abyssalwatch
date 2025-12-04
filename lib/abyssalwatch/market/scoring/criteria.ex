defmodule Abyssalwatch.Market.Scoring.Criteria do
  @moduledoc """
  Scoring criteria configuration for TOPSIS algorithm.
  Defines weights and attribute directionality.
  """

  defstruct [
    :price_weight,
    :performance_weight,
    :efficiency_weight,
    :volume_weight,
    :attribute_weights,
    :attribute_directions
  ]

  @type direction :: :higher_better | :lower_better
  @type t :: %__MODULE__{
          price_weight: float(),
          performance_weight: float(),
          efficiency_weight: float(),
          volume_weight: float(),
          attribute_weights: %{String.t() => float()},
          attribute_directions: %{String.t() => direction()}
        }

  @doc """
  Default balanced scoring criteria.
  """
  def default do
    %__MODULE__{
      price_weight: 0.25,
      performance_weight: 0.35,
      efficiency_weight: 0.30,
      volume_weight: 0.10,
      attribute_weights: %{},
      attribute_directions: %{}
    }
  end

  @doc """
  Conservative scoring - prioritizes cost efficiency.
  """
  def conservative do
    %__MODULE__{
      price_weight: 0.40,
      performance_weight: 0.20,
      efficiency_weight: 0.35,
      volume_weight: 0.05,
      attribute_weights: %{},
      attribute_directions: %{}
    }
  end

  @doc """
  Aggressive scoring - prioritizes raw performance.
  """
  def aggressive do
    %__MODULE__{
      price_weight: 0.10,
      performance_weight: 0.50,
      efficiency_weight: 0.25,
      volume_weight: 0.15,
      attribute_weights: %{},
      attribute_directions: %{}
    }
  end

  @doc """
  Create criteria from user parameters.
  """
  def from_params(params) when is_map(params) do
    %__MODULE__{
      price_weight: parse_weight(params["price_weight"], 0.25),
      performance_weight: parse_weight(params["performance_weight"], 0.35),
      efficiency_weight: parse_weight(params["efficiency_weight"], 0.30),
      volume_weight: parse_weight(params["volume_weight"], 0.10),
      attribute_weights: parse_attribute_weights(params["attribute_weights"]),
      attribute_directions: parse_attribute_directions(params["attribute_directions"])
    }
    |> normalize_weights()
  end

  @doc """
  Get preset criteria by name.
  """
  def preset(name) do
    case name do
      "conservative" -> conservative()
      "aggressive" -> aggressive()
      _ -> default()
    end
  end

  @doc """
  Convert criteria to a weight vector for TOPSIS.
  """
  def to_weight_vector(%__MODULE__{} = criteria, attributes) do
    Enum.map(attributes, fn attr ->
      Map.get(criteria.attribute_weights, attr, 1.0)
    end)
  end

  @doc """
  Get the direction for an attribute (higher_better or lower_better).
  """
  def direction(%__MODULE__{} = criteria, attr_name, default_direction \\ :higher_better) do
    Map.get(criteria.attribute_directions, attr_name, default_direction)
  end

  @doc """
  Merge criteria with module type base attributes.
  """
  def merge_with_module_type(%__MODULE__{} = criteria, module_type) do
    base_attrs = module_type.base_attributes || %{}

    directions =
      Enum.reduce(base_attrs, criteria.attribute_directions, fn {name, meta}, acc ->
        case meta do
          %{direction: dir} -> Map.put_new(acc, name, dir)
          %{"direction" => dir} -> Map.put_new(acc, name, String.to_atom(dir))
          _ -> acc
        end
      end)

    %{criteria | attribute_directions: directions}
  end

  # Private helpers

  defp parse_weight(nil, default), do: default
  defp parse_weight(value, _default) when is_float(value), do: value
  defp parse_weight(value, _default) when is_integer(value), do: value / 1.0

  defp parse_weight(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> default
    end
  end

  defp parse_weight(_, default), do: default

  defp parse_attribute_weights(nil), do: %{}

  defp parse_attribute_weights(weights) when is_map(weights) do
    Enum.reduce(weights, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), parse_weight(v, 1.0))
    end)
  end

  defp parse_attribute_weights(_), do: %{}

  defp parse_attribute_directions(nil), do: %{}

  defp parse_attribute_directions(dirs) when is_map(dirs) do
    Enum.reduce(dirs, %{}, fn {k, v}, acc ->
      direction = parse_direction(v)
      Map.put(acc, to_string(k), direction)
    end)
  end

  defp parse_attribute_directions(_), do: %{}

  defp parse_direction(:higher_better), do: :higher_better
  defp parse_direction(:lower_better), do: :lower_better
  defp parse_direction("higher_better"), do: :higher_better
  defp parse_direction("lower_better"), do: :lower_better
  defp parse_direction(_), do: :higher_better

  defp normalize_weights(%__MODULE__{} = criteria) do
    total =
      criteria.price_weight +
        criteria.performance_weight +
        criteria.efficiency_weight +
        criteria.volume_weight

    if total > 0 do
      %{
        criteria
        | price_weight: criteria.price_weight / total,
          performance_weight: criteria.performance_weight / total,
          efficiency_weight: criteria.efficiency_weight / total,
          volume_weight: criteria.volume_weight / total
      }
    else
      default()
    end
  end
end
