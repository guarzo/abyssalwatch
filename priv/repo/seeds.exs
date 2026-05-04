# Seed `Abyssalwatch.Market.ModuleType` rows.
#
# Run with: mix run priv/repo/seeds.exs
#
# If the EVE SDE files are present at /tmp/sde, seeds the full set derived from
# the SDE. Otherwise falls back to a small hardcoded list.
#
# To download the SDE first:
#   curl -sL "https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip" -o /tmp/sde.zip
#   unzip -o /tmp/sde.zip -d /tmp/sde/

alias Abyssalwatch.Market.SDE.{Loader, Seeder}

case Seeder.seed_from_sde() do
  {:ok, {ok_count, err_count}} ->
    IO.puts("\n✅ Seeded #{ok_count} module types from SDE (#{err_count} errors)")

  {:error, {:missing_files, missing}} ->
    IO.puts("""
    \n⚠️  SDE files not found at #{Loader.default_path()}. Missing: #{Enum.join(missing, ", ")}

    Falling back to hardcoded module types. To seed from the full SDE, run:

      curl -sL "https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip" -o /tmp/sde.zip
      unzip -o /tmp/sde.zip -d /tmp/sde/
      mix run priv/repo/seeds.exs
    """)

    {:ok, {ok_count, err_count}} = Seeder.seed_fallback()
    IO.puts("\n✅ Seeded #{ok_count} fallback module types (#{err_count} errors)")
end
