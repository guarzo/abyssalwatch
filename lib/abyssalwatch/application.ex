defmodule Abyssalwatch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AbyssalwatchWeb.Telemetry,
      Abyssalwatch.Repo,
      {DNSCluster, query: Application.get_env(:abyssalwatch, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Abyssalwatch.PubSub},
      # Mutamarket API infrastructure
      Abyssalwatch.Market.Mutamarket.Cache,
      Abyssalwatch.Market.Mutamarket.RateLimiter,
      # User preferences storage (Phase 1: anonymous sessions)
      Abyssalwatch.Preferences.Store,
      # Task supervisor for async notifications (Discord webhooks)
      {Task.Supervisor, name: Abyssalwatch.NotificationTasks},
      # Watchlist monitoring
      {Abyssalwatch.Watchlists.Monitor, []},
      # Start to serve requests, typically the last entry
      AbyssalwatchWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Abyssalwatch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AbyssalwatchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
