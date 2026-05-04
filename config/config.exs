# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Register custom MIME types so LiveView's allow_upload accepts these extensions.
config :mime, :types, %{
  "application/vnd.eve.eft" => ["eft"]
}

config :abyssalwatch,
  ecto_repos: [Abyssalwatch.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    Abyssalwatch.Accounts,
    Abyssalwatch.Market,
    Abyssalwatch.Watchlists,
    Abyssalwatch.Fittings
  ],
  # Base URL for shareable links
  base_url: "http://localhost:4000"

# EVE SSO OAuth2 Configuration (development defaults)
# In production, these should be set via environment variables
config :abyssalwatch, :eve_sso,
  client_id: System.get_env("EVE_CLIENT_ID", "your_client_id_here"),
  client_secret: System.get_env("EVE_CLIENT_SECRET", "your_client_secret_here"),
  callback_url: System.get_env("EVE_CALLBACK_URL", "http://localhost:4000/auth/eve/callback")

# Ash configuration
config :ash,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

# Configure the endpoint
config :abyssalwatch, AbyssalwatchWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AbyssalwatchWeb.ErrorHTML, json: AbyssalwatchWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Abyssalwatch.PubSub,
  live_view: [signing_salt: "XknzCUYD"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :abyssalwatch, Abyssalwatch.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  abyssalwatch: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  abyssalwatch: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# SDE auto-refresh: set to false to skip the boot-time refresh task.
config :abyssalwatch, sde_auto_refresh: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
