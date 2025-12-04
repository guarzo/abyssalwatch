defmodule Abyssalwatch.Market.Scoring.Topsis do
  @moduledoc """
  TOPSIS (Technique for Order of Preference by Similarity to Ideal Solution)
  multi-criteria decision-making algorithm.

  ## Algorithm Steps:
  1. Build decision matrix from module attributes
  2. Normalize matrix using vector normalization
  3. Apply criteria weights
  4. Determine ideal and anti-ideal solutions
  5. Calculate Euclidean distance to ideal/anti-ideal
  6. Compute relative closeness score (0-1)
  """

  alias Abyssalwatch.Market.Scoring.Criteria

  @type module_data :: %{
          id: String.t(),
          price: Decimal.t() | number(),
          attributes: map()
        }

  @type scored_module :: %{
          module: module_data(),
          score: float(),
          breakdown: map()
        }

  @doc """
  Apply TOPSIS scoring to a list of modules.

  Returns modules sorted by score descending, each with a score (0-1)
  where 1 is closest to ideal and 0 is closest to anti-ideal.
  """
  @spec score([module_data()], Criteria.t()) :: [scored_module()]
  def score([], _criteria), do: []
  def score([single], _criteria), do: [%{module: single, score: 1.0, breakdown: %{}}]

  def score(modules, %Criteria{} = criteria) when is_list(modules) do
    # Extract relevant attributes from all modules
    attributes = extract_common_attributes(modules)

    if Enum.empty?(attributes) do
      # No common attributes, return uniform scores
      Enum.map(modules, &%{module: &1, score: 0.5, breakdown: %{}})
    else
      modules
      |> build_decision_matrix(attributes, criteria)
      |> normalize_matrix()
      |> apply_weights(criteria, attributes)
      |> calculate_ideal_solutions(criteria, attributes)
      |> calculate_distances()
      |> calculate_closeness()
      |> rank_modules(modules, attributes)
    end
  end

  @doc """
  Score a single module relative to known ideal values.
  Useful for quick individual scoring without a full comparison set.
  """
  def score_single(module, %Criteria{} = _criteria, ideal_values) do
    attributes = Map.keys(ideal_values)

    if Enum.empty?(attributes) do
      0.5
    else
      values =
        Enum.map(attributes, fn attr ->
          get_attribute_value(module, attr)
        end)

      ideal =
        Enum.map(attributes, fn attr ->
          ideal_values[attr][:ideal] || 0.0
        end)

      anti_ideal =
        Enum.map(attributes, fn attr ->
          ideal_values[attr][:anti_ideal] || 0.0
        end)

      d_plus = euclidean_distance(values, ideal)
      d_minus = euclidean_distance(values, anti_ideal)

      if d_plus + d_minus > 0 do
        d_minus / (d_plus + d_minus)
      else
        0.5
      end
    end
  end

  # Step 1: Build decision matrix
  defp build_decision_matrix(modules, attributes, criteria) do
    # Include price as an attribute
    all_attributes = ["_price" | attributes]

    matrix =
      for module <- modules do
        for attr <- all_attributes do
          if attr == "_price" do
            get_price_value(module)
          else
            get_attribute_value(module, attr)
          end
        end
      end

    {matrix, all_attributes, criteria}
  end

  # Step 2: Vector normalization
  defp normalize_matrix({matrix, attributes, criteria}) do
    transposed = transpose(matrix)

    normalized_cols =
      for col <- transposed do
        norm = :math.sqrt(Enum.sum(Enum.map(col, fn x -> x * x end)))

        if norm > 0.0001 do
          Enum.map(col, fn x -> x / norm end)
        else
          Enum.map(col, fn _ -> 0.0 end)
        end
      end

    {transpose(normalized_cols), attributes, criteria}
  end

  # Step 3: Apply weights
  defp apply_weights({normalized, attributes, criteria}, _criteria, _attrs) do
    weights = calculate_weights(attributes, criteria)

    weighted =
      for row <- normalized do
        Enum.zip(row, weights)
        |> Enum.map(fn {val, weight} -> val * weight end)
      end

    {weighted, attributes, criteria}
  end

  # Step 4: Calculate ideal and anti-ideal solutions
  defp calculate_ideal_solutions({weighted, attributes, criteria}, _criteria, _attrs) do
    transposed = transpose(weighted)

    {ideal, anti_ideal} =
      Enum.zip(transposed, attributes)
      |> Enum.map(fn {col, attr} ->
        direction = get_direction(attr, criteria)

        case direction do
          :higher_better ->
            {Enum.max(col), Enum.min(col)}

          :lower_better ->
            {Enum.min(col), Enum.max(col)}
        end
      end)
      |> Enum.unzip()

    {weighted, ideal, anti_ideal}
  end

  # Step 5: Calculate Euclidean distances
  defp calculate_distances({weighted, ideal, anti_ideal}) do
    distances =
      for row <- weighted do
        d_plus = euclidean_distance(row, ideal)
        d_minus = euclidean_distance(row, anti_ideal)
        {d_plus, d_minus}
      end

    distances
  end

  # Step 6: Calculate relative closeness
  defp calculate_closeness(distances) do
    Enum.map(distances, fn {d_plus, d_minus} ->
      total = d_plus + d_minus

      if total > 0.0001 do
        d_minus / total
      else
        0.5
      end
    end)
  end

  # Step 7: Rank and return results
  defp rank_modules(scores, modules, attributes) do
    Enum.zip(modules, scores)
    |> Enum.map(fn {module, score} ->
      %{
        module: module,
        score: Float.round(score, 4),
        breakdown: build_breakdown(module, attributes, score)
      }
    end)
    |> Enum.sort_by(fn %{score: score} -> score end, :desc)
  end

  # Helper functions

  defp extract_common_attributes(modules) do
    # Get attributes that appear in at least 50% of modules
    all_attrs =
      modules
      |> Enum.flat_map(fn m ->
        (m[:attributes] || m.attributes || %{})
        |> Map.keys()
      end)

    attr_counts =
      all_attrs
      |> Enum.frequencies()

    threshold = max(1, div(length(modules), 2))

    attr_counts
    |> Enum.filter(fn {_attr, count} -> count >= threshold end)
    |> Enum.map(fn {attr, _count} -> attr end)
    |> Enum.sort()
  end

  defp get_attribute_value(module, attr) do
    attrs = module[:attributes] || module.attributes || %{}

    case Map.get(attrs, attr) do
      nil ->
        0.0

      value when is_number(value) ->
        value / 1.0

      value when is_binary(value) ->
        case Float.parse(value) do
          {float, _} -> float
          :error -> 0.0
        end

      _ ->
        0.0
    end
  end

  defp get_price_value(module) do
    price = module[:price] || module.price

    case price do
      nil -> 0.0
      %Decimal{} = d -> Decimal.to_float(d)
      value when is_number(value) -> value / 1.0
      _ -> 0.0
    end
  end

  defp calculate_weights(attributes, %Criteria{} = criteria) do
    base_weight = 1.0 / length(attributes)

    Enum.map(attributes, fn attr ->
      if attr == "_price" do
        # Price gets its own weight from criteria
        criteria.price_weight
      else
        # Other attributes share performance weight, adjusted by custom weights
        custom = Map.get(criteria.attribute_weights, attr, 1.0)
        criteria.performance_weight * custom * base_weight
      end
    end)
    |> normalize_weight_vector()
  end

  defp normalize_weight_vector(weights) do
    total = Enum.sum(weights)

    if total > 0 do
      Enum.map(weights, &(&1 / total))
    else
      count = length(weights)
      Enum.map(weights, fn _ -> 1.0 / count end)
    end
  end

  defp get_direction("_price", _criteria), do: :lower_better

  defp get_direction(attr, %Criteria{} = criteria) do
    Map.get(criteria.attribute_directions, attr, :higher_better)
  end

  defp euclidean_distance(a, b) when length(a) == length(b) do
    Enum.zip(a, b)
    |> Enum.map(fn {x, y} -> (x - y) * (x - y) end)
    |> Enum.sum()
    |> :math.sqrt()
  end

  defp euclidean_distance(_, _), do: 0.0

  defp transpose([]), do: []
  defp transpose([[] | _]), do: []

  defp transpose(matrix) do
    matrix
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
  end

  defp build_breakdown(module, attributes, total_score) do
    attrs = module[:attributes] || module.attributes || %{}

    attribute_scores =
      Enum.reduce(attributes, %{}, fn attr, acc ->
        if attr != "_price" do
          value = Map.get(attrs, attr)
          Map.put(acc, attr, value)
        else
          acc
        end
      end)

    %{
      total_score: total_score,
      price: get_price_value(module),
      attributes: attribute_scores
    }
  end
end
