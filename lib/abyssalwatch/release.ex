defmodule Abyssalwatch.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :abyssalwatch

  alias Abyssalwatch.Market.SDE.{Loader, Seeder}

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Seeds `Abyssalwatch.Market.ModuleType` rows.

  Intended to be invoked once after a deploy via:

      /app/bin/abyssalwatch eval 'Abyssalwatch.Release.seed()'

  If the EVE SDE files are present at `/tmp/sde/` (or a custom `sde_path`),
  seeds the full set derived from the SDE. Otherwise falls back to the
  hardcoded module-type list.

  Returns `{:ok, {ok_count, err_count}}`.
  """
  def seed(sde_path \\ Loader.default_path()) do
    start_app()

    case safe_seed_from_sde(sde_path) do
      {:ok, {ok_count, err_count}} ->
        IO.puts("Seeded #{ok_count} module types from SDE (#{err_count} errors)")
        {:ok, {ok_count, err_count}}

      {:error, {:missing_files, missing}} ->
        IO.puts("SDE files missing at #{sde_path}: #{Enum.join(missing, ", ")}")
        IO.puts("Falling back to hardcoded module types.")
        run_fallback()

      {:error, reason} ->
        IO.puts(
          "Seeder.seed_from_sde failed at #{sde_path}: #{inspect(reason)}. " <>
            "Falling back to hardcoded module types."
        )

        run_fallback()
    end
  end

  # Wraps Seeder.seed_from_sde/1 to convert any raised exception (e.g. from
  # JSON decoding or Ash.create) into a structured `{:error, ...}` so the
  # caller can fall back gracefully instead of crashing release boot.
  defp safe_seed_from_sde(sde_path) do
    Seeder.seed_from_sde(sde_path)
  rescue
    exception ->
      IO.puts(
        "Seeder.seed_from_sde raised at #{sde_path} (Loader.load_all path): " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:exception, exception}}
  end

  defp run_fallback do
    case Seeder.seed_fallback() do
      {:ok, {ok_count, err_count}} ->
        IO.puts("Seeded #{ok_count} fallback module types (#{err_count} errors)")
        {:ok, {ok_count, err_count}}
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  # `seed/1` needs the full app started (Ash, telemetry, repo) — `load_app/0`
  # only loads the app metadata.
  defp start_app do
    Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(@app)
  end
end
