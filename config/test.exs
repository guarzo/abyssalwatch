import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :abyssalwatch, Abyssalwatch.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "db",
  database: "abyssalwatch_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :abyssalwatch, AbyssalwatchWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "DQmc5NixGbcX7TaPidqd/VbZWVb7JTXFrN8QkW017XjSGt5d8id9JieX8lfGIC57",
  server: false

# In test we don't send emails
config :abyssalwatch, Abyssalwatch.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :abyssalwatch, Abyssalwatch.Market.SDE.Downloader,
  req_options: [plug: {Req.Test, Abyssalwatch.Market.SDE.Downloader}]

config :abyssalwatch, sde_auto_refresh: false
