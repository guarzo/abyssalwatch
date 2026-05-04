defmodule Abyssalwatch.Market.SDE.Loader do
  @moduledoc """
  Loads data from EVE Online SDE (Static Data Export) JSON Lines files.

  Expects the SDE files to be unzipped at `@default_sde_path` (or a custom
  path passed in). Used by both `priv/repo/seeds.exs` (dev) and
  `Abyssalwatch.Release.seed/0` (production).
  """

  @default_sde_path "/tmp/sde"

  @required_files ~w(types.jsonl groups.jsonl dogmaAttributes.jsonl typeDogma.jsonl)

  @doc "Returns the default SDE path (`/tmp/sde`)."
  def default_path, do: @default_sde_path

  @doc """
  Returns the list of files that must exist for `load_all/1` to succeed.
  """
  def required_files, do: @required_files

  @doc """
  Returns the list of required files that are missing under `sde_path`.
  """
  def missing_files(sde_path \\ @default_sde_path) do
    Enum.filter(@required_files, fn file ->
      not File.exists?(Path.join(sde_path, file))
    end)
  end

  @doc """
  Loads all four SDE files and returns
  `{:ok, %{types: ..., groups: ..., dogma_attrs: ..., type_dogma: ...}}` or
  `{:error, {:missing_files, [...]}}` if any required file is absent.
  """
  def load_all(sde_path \\ @default_sde_path) do
    case missing_files(sde_path) do
      [] ->
        {:ok,
         %{
           types: load_types(sde_path),
           groups: load_groups(sde_path),
           dogma_attrs: load_dogma_attributes(sde_path),
           type_dogma: load_type_dogma(sde_path)
         }}

      missing ->
        {:error, {:missing_files, missing}}
    end
  end

  def load_types(sde_path \\ @default_sde_path), do: read_index(sde_path, "types.jsonl")
  def load_groups(sde_path \\ @default_sde_path), do: read_index(sde_path, "groups.jsonl")

  def load_dogma_attributes(sde_path \\ @default_sde_path),
    do: read_index(sde_path, "dogmaAttributes.jsonl")

  def load_type_dogma(sde_path \\ @default_sde_path),
    do: read_index(sde_path, "typeDogma.jsonl")

  defp read_index(sde_path, filename) do
    sde_path
    |> read_jsonl(filename)
    |> Enum.reduce(%{}, fn item, acc -> Map.put(acc, item["_key"], item) end)
  end

  defp read_jsonl(sde_path, filename) do
    path = Path.join(sde_path, filename)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.filter(&(&1 != ""))
      |> Stream.map(&Jason.decode!/1)
      |> Enum.to_list()
    else
      IO.puts("Warning: #{path} not found.")
      []
    end
  end
end
