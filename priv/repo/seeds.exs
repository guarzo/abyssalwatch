# Seed `Abyssalwatch.Market.ModuleType` rows.
#
# Run with: mix run priv/repo/seeds.exs
#
# If SDE_ZIP env var points to an SDE zip, seeds from it. Otherwise falls back
# to a small hardcoded list.
#
# To download the SDE first:
#   curl -sL "https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip" -o /tmp/sde.zip
#   SDE_ZIP=/tmp/sde.zip mix run priv/repo/seeds.exs

sde_zip = System.get_env("SDE_ZIP")

case sde_zip do
  nil ->
    {:ok, _} = Abyssalwatch.Market.SDE.Seeder.seed_fallback()

  path ->
    {:ok, _} = Abyssalwatch.Market.SDE.Seeder.seed_from_zip(path)
end
