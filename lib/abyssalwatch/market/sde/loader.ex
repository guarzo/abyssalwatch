defmodule Abyssalwatch.Market.SDE.Loader do
  @moduledoc """
  Streams data from EVE Online SDE (Static Data Export) zipped JSONL files.

  Open an archive once with `with_archive/2`, then pull entries lazily via
  `stream_entry/2`. The archive index is held by `:zip`; only one entry's
  bytes live in RAM at a time, and within an entry consumers see lazily
  decoded JSON maps via `Stream`. This bounds peak memory to roughly one
  JSONL file plus whatever working set the seeder chooses to retain —
  never the full multi-file SDE.
  """

  require Logger

  @required_files ~w(types.jsonl groups.jsonl dogmaAttributes.jsonl typeDogma.jsonl)

  @doc "Returns the list of JSONL files we expect to find inside the SDE zip."
  def required_files, do: @required_files

  @doc """
  Opens a SDE zip archive at `zip_path`, passes the handle to `fun`, and
  closes it afterwards. Returns whatever `fun` returns.
  """
  def with_archive(zip_path, fun) when is_function(fun, 1) do
    case :zip.zip_open(String.to_charlist(zip_path), [:memory]) do
      {:ok, handle} ->
        try do
          fun.(handle)
        after
          :zip.zip_close(handle)
        end

      {:error, reason} ->
        raise "failed to open SDE zip at #{zip_path}: #{inspect(reason)}"
    end
  end

  @doc """
  Returns a `Stream` of decoded JSON maps from `filename` inside the open
  zip `handle`. Filename matching is suffix-based so nested paths inside
  the zip (e.g. `eve-online-static-data/types.jsonl`) work.

  Malformed lines are skipped with a warning.
  """
  def stream_entry(handle, filename) do
    Stream.resource(
      fn -> read_entry_lines(handle, filename) end,
      fn
        [] -> {:halt, nil}
        [line | rest] -> {[line], rest}
      end,
      fn _ -> :ok end
    )
    |> Stream.with_index(1)
    |> Stream.flat_map(fn {line, line_no} -> decode_line(line, line_no, filename) end)
  end

  defp read_entry_lines(handle, filename) do
    case :zip.zip_get(String.to_charlist(filename), handle) do
      {:ok, {_name, body}} ->
        split_lines(body)

      {:error, _} ->
        case find_entry(handle, filename) do
          nil ->
            Logger.warning("SDE zip is missing #{filename}")
            []

          full_name ->
            {:ok, {_, body}} = :zip.zip_get(full_name, handle)
            split_lines(body)
        end
    end
  end

  defp find_entry(handle, suffix) do
    suffix_charlist = String.to_charlist("/" <> suffix)
    plain_charlist = String.to_charlist(suffix)

    case :zip.zip_list_dir(handle) do
      {:ok, entries} ->
        Enum.find_value(entries, fn
          {:zip_file, name, _info, _comment, _offset, _size} ->
            cond do
              List.starts_with?(Enum.reverse(name), Enum.reverse(suffix_charlist)) -> name
              name == plain_charlist -> name
              true -> nil
            end

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  defp split_lines(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
  end

  defp split_lines(body) when is_list(body) do
    body |> IO.iodata_to_binary() |> split_lines()
  end

  defp decode_line(line, line_no, filename) do
    case Jason.decode(line) do
      {:ok, map} ->
        [map]

      {:error, reason} ->
        Logger.warning(
          "skipping malformed JSON in #{filename} at line #{line_no}: #{inspect(reason)}"
        )

        []
    end
  end
end
