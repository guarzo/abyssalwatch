defmodule Abyssalwatch.SDEFixture do
  @moduledoc """
  Builds tiny in-memory or on-disk SDE-shaped zips for tests.
  """

  @doc """
  Writes a zip at `path` containing `entries` — a map of filename to JSONL
  string. Returns `path`.
  """
  def write_zip(path, entries) when is_map(entries) do
    File.mkdir_p!(Path.dirname(path))

    zip_entries =
      Enum.map(entries, fn {name, body} ->
        {String.to_charlist(name), body}
      end)

    {:ok, _} = :zip.create(String.to_charlist(path), zip_entries)
    path
  end

  @doc "Encodes a list of maps as one JSON object per line."
  def jsonl(rows) when is_list(rows) do
    rows
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
