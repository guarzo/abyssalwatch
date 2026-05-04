defmodule Abyssalwatch.Market.SDE.Refresher do
  @moduledoc """
  Boot-time orchestrator: HEAD the SDE URL, compare build_number against
  the stored marker, download + seed if stale. Multi-machine safe via a
  Postgres advisory lock.

  All failures are caught and logged. The function never raises.
  """

  require Logger

  alias Abyssalwatch.Market.SDE.{Downloader, Seeder, Version}
  alias Abyssalwatch.Repo

  @advisory_lock_key :erlang.phash2(:sde_refresh)

  @doc """
  Runs one refresh pass. Returns:

    * `:up_to_date` — marker matches latest build_number, nothing done.
    * `{:ok, %{build_number: integer, type_count: integer}}` — refreshed.
    * `:error` — failed; check logs. Application state unchanged.
  """
  def run do
    try do
      do_run()
    rescue
      e ->
        Logger.warning(
          "SDE refresher crashed: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        :error
    catch
      kind, reason ->
        Logger.warning("SDE refresher exited (#{kind}): #{inspect(reason)}")
        :error
    end
  end

  defp do_run do
    with {:ok, head} <- head_or_log(),
         marker = current_marker(),
         :stale <- compare(marker, head) do
      with_advisory_lock(fn ->
        case compare(current_marker(), head) do
          :match -> :up_to_date
          :stale -> download_and_seed(head)
        end
      end)
    else
      :match ->
        Logger.info("SDE up to date (build #{(current_marker() || %{}).build_number})")
        :up_to_date

      {:error, _} ->
        :error
    end
  end

  defp head_or_log do
    case Downloader.head_latest() do
      {:ok, head} = ok ->
        Logger.info("SDE HEAD: build #{head.build_number}")
        ok

      {:error, reason} = err ->
        Logger.warning("SDE HEAD failed: #{inspect(reason)}")
        err
    end
  end

  defp current_marker do
    case Ash.read(Version) do
      {:ok, [marker | _]} -> marker
      _ -> nil
    end
  end

  defp compare(nil, _head), do: :stale
  defp compare(%{build_number: b}, %{build_number: b}), do: :match
  defp compare(_, _), do: :stale

  defp with_advisory_lock(fun) do
    Repo.checkout(fn ->
      Repo.query!("SELECT pg_advisory_lock($1)", [@advisory_lock_key])

      try do
        fun.()
      after
        Repo.query!("SELECT pg_advisory_unlock($1)", [@advisory_lock_key])
      end
    end)
  end

  defp download_and_seed(head) do
    tmp = Path.join(System.tmp_dir!(), "sde-#{head.build_number}.zip")

    try do
      case Downloader.download_to(tmp) do
        :ok ->
          seed_and_record(head, tmp)

        {:error, reason} ->
          Logger.warning("SDE download failed: #{inspect(reason)}")
          :error
      end
    after
      _ = File.rm(tmp)
    end
  end

  defp seed_and_record(head, zip_path) do
    case Seeder.seed_from_zip(zip_path) do
      {:ok, {ok_count, 0}} ->
        Logger.info("SDE seeded: #{ok_count} ok, 0 errors")
        upsert_marker(head, ok_count)

      {:ok, {ok_count, err_count}} ->
        Logger.warning(
          "SDE partial seed (#{ok_count} ok, #{err_count} errors); " <>
            "leaving marker unchanged so the next boot retries"
        )

        :error

      {:error, reason} ->
        Logger.warning("SDE seed_from_zip failed: #{inspect(reason)}")
        :error
    end
  end

  defp upsert_marker(head, ok_count) do
    last_modified = parse_http_date(head.last_modified)

    attrs = %{
      id: 1,
      build_number: head.build_number,
      etag: head.etag,
      last_modified: last_modified,
      seeded_at: DateTime.utc_now() |> DateTime.truncate(:second),
      type_count: ok_count
    }

    case Ash.create(Version, attrs, action: :upsert, upsert?: true) do
      {:ok, _} ->
        {:ok, %{build_number: head.build_number, type_count: ok_count}}

      {:error, reason} ->
        Logger.warning("SDE marker upsert failed: #{inspect(reason)}")
        :error
    end
  end

  defp parse_http_date(nil), do: nil

  defp parse_http_date(s) when is_binary(s) do
    # RFC1123: "Fri, 01 May 2026 11:48:57 GMT"
    case Regex.run(
           ~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
           s
         ) do
      [_, day, mon_s, year, h, m, sec] ->
        months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
        mon = Enum.find_index(months, &(&1 == mon_s))

        if mon do
          {:ok, dt} =
            NaiveDateTime.new(
              String.to_integer(year),
              mon + 1,
              String.to_integer(day),
              String.to_integer(h),
              String.to_integer(m),
              String.to_integer(sec)
            )

          DateTime.from_naive!(dt, "Etc/UTC")
        end

      _ ->
        nil
    end
  end
end
