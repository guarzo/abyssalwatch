defmodule Abyssalwatch.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :abyssalwatch

  alias Abyssalwatch.Market.SDE.Seeder

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
  Seeds `ModuleType` rows.

  Pass `:default` (the default) to seed from the hardcoded fallback list. Pass
  a path to an SDE zip to seed from it. Manual escape hatch for ops:

      /app/bin/abyssalwatch eval 'Abyssalwatch.Release.seed("/tmp/sde.zip")'
  """
  def seed(path \\ :default) do
    start_app()

    case path do
      :default ->
        run_fallback()

      zip_path when is_binary(zip_path) ->
        case safe_seed_from_zip(zip_path) do
          {:ok, {ok_count, err_count}} ->
            IO.puts("Seeded #{ok_count} module types from SDE (#{err_count} errors)")
            {:ok, {ok_count, err_count}}

          {:error, reason} ->
            IO.puts(
              "Seeder.seed_from_zip failed at #{zip_path}: #{inspect(reason)}. " <>
                "Falling back to hardcoded module types."
            )

            run_fallback()
        end
    end
  end

  @doc "Synchronously runs the SDE refresher (download + seed if stale)."
  def refresh_now do
    start_app()
    Abyssalwatch.Market.SDE.Refresher.run()
  end

  defp safe_seed_from_zip(zip_path) do
    Seeder.seed_from_zip(zip_path)
  rescue
    exception ->
      IO.puts(
        "Seeder.seed_from_zip raised at #{zip_path}: " <>
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
