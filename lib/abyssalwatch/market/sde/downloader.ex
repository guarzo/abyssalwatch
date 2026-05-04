defmodule Abyssalwatch.Market.SDE.Downloader do
  @moduledoc """
  Thin wrapper over `Req` for SDE HEAD + download. Isolated so tests can
  stub it via `Req.Test` without touching `Refresher` logic.
  """

  @latest_url "https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip"

  @doc """
  HEADs the SDE URL **without following the 302**, so we can read the
  `x-sde-build-number` header that CCP only sets on the redirect response.

  Returns `{:ok, %{build_number: integer | nil, etag: binary | nil,
  last_modified: binary | nil, url: binary}}` or `{:error, term}`.

  Build number resolution order:
    1. `x-sde-build-number` response header (preferred)
    2. parsed from the redirect target path (`…-NNNNNNN-jsonl.zip`)
  """
  def head_latest(opts \\ []) do
    req =
      [method: :head, url: @latest_url, redirect: false]
      |> Keyword.merge(req_opts())
      |> Keyword.merge(opts)
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: status, headers: headers}}
      when status in 200..299 or status in 300..399 ->
        location = header(headers, "location")

        {:ok,
         %{
           build_number:
             header(headers, "x-sde-build-number")
             |> parse_int()
             |> fallback(fn -> build_number_from_url(location) end),
           etag: header(headers, "etag"),
           last_modified: header(headers, "last-modified"),
           url: location || @latest_url
         }}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streams the SDE zip to `dest_path`. Returns `:ok` or `{:error, reason}`.
  """
  def download_to(dest_path, opts \\ []) do
    File.mkdir_p!(Path.dirname(dest_path))

    req =
      [url: @latest_url, into: File.stream!(dest_path)]
      |> Keyword.merge(req_opts())
      |> Keyword.merge(opts)
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:bad_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req_opts do
    Application.get_env(:abyssalwatch, __MODULE__, [])
    |> Keyword.get(:req_options, [])
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {^name, v} -> List.wrap(v) |> List.first()
      _ -> nil
    end)
  end

  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      nil -> nil
      [v | _] -> v
      v when is_binary(v) -> v
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp fallback(nil, fun), do: fun.()
  defp fallback(value, _fun), do: value

  # Extracts NNNNNNN from a path like
  # "…/eve-online-static-data-3328718-jsonl.zip".
  defp build_number_from_url(nil), do: nil

  defp build_number_from_url(url) when is_binary(url) do
    case Regex.run(~r/static-data-(\d+)-jsonl\.zip/, url) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end
end
