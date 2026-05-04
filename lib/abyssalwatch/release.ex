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

    case Seeder.seed_from_sde(sde_path) do
      {:ok, {ok_count, err_count}} ->
        IO.puts("Seeded #{ok_count} module types from SDE (#{err_count} errors)")
        {:ok, {ok_count, err_count}}

      {:error, {:missing_files, missing}} ->
        IO.puts("SDE files missing at #{sde_path}: #{Enum.join(missing, ", ")}")
        IO.puts("Falling back to hardcoded module types.")
        {ok_count, err_count} = Seeder.seed_fallback()
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
