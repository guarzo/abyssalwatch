# AbyssalWatch Implementation Plan

**Project:** AbyssalWatch - EVE Online Abyssal Module Analysis Platform
**Stack:** Elixir, Phoenix, Ash Framework, LiveView, PostgreSQL
**Created:** December 2025
**Status:** Planning

---

## Executive Summary

AbyssalWatch is a reimplementation of the Abyssal Module functionality from EVE Corp Tools, extracted and rebuilt using Elixir/Ash for improved maintainability, real-time capabilities, and developer experience. The application enables EVE Online players to search, analyze, score, and optimize abyssal (mutaplasmid-modified) modules for their ship fittings.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Technology Decisions](#2-technology-decisions)
3. [Domain Model](#3-domain-model)
4. [Phase 1: Foundation & Module Search](#4-phase-1-foundation--module-search)
5. [Phase 2: Watchlists & Notifications](#5-phase-2-watchlists--notifications)
6. [Phase 3: Optimization Engine](#6-phase-3-optimization-engine)
7. [Phase 4: ESI Integration](#7-phase-4-esi-integration)
8. [API Design](#8-api-design)
9. [Testing Strategy](#9-testing-strategy)
10. [Deployment Considerations](#10-deployment-considerations)

---

## 1. Architecture Overview

### Project Structure

```
abyssalwatch/
├── lib/
│   ├── abyssalwatch/
│   │   ├── application.ex              # OTP Application supervisor
│   │   ├── repo.ex                     # Ecto Repo
│   │   │
│   │   ├── accounts/                   # User/Auth domain (EVE SSO)
│   │   │   ├── accounts.ex             # Ash Domain
│   │   │   ├── user.ex                 # Ash Resource (EVE character data)
│   │   │   ├── notification_settings.ex # User notification preferences (Discord, etc.)
│   │   │   ├── eve_auth.ex             # EVE SSO OAuth2 implementation
│   │   │   └── token.ex                # Session tokens
│   │   │
│   │   ├── market/                     # Market data domain
│   │   │   ├── market.ex               # Ash Domain
│   │   │   ├── resources/
│   │   │   │   ├── module.ex           # Abyssal module resource
│   │   │   │   ├── module_type.ex      # Module type definitions
│   │   │   │   └── module_attribute.ex # Attribute metadata
│   │   │   ├── mutamarket/
│   │   │   │   ├── client.ex           # HTTP client for Mutamarket API
│   │   │   │   ├── cache.ex            # ETS-based caching
│   │   │   │   └── rate_limiter.ex     # Token bucket rate limiting
│   │   │   └── scoring/
│   │   │       ├── topsis.ex           # TOPSIS algorithm
│   │   │       ├── criteria.ex         # Scoring criteria structs
│   │   │       └── presets.ex          # Default/Conservative/Aggressive
│   │   │
│   │   ├── watchlists/                 # Watchlist domain
│   │   │   ├── watchlists.ex           # Ash Domain
│   │   │   ├── resources/
│   │   │   │   ├── watchlist.ex        # Watchlist resource
│   │   │   │   └── notification.ex     # Notification log resource
│   │   │   ├── monitor.ex              # GenServer for background checks
│   │   │   ├── matcher.ex              # Module matching logic
│   │   │   ├── notifier.ex             # Notification dispatch (PubSub + Discord)
│   │   │   └── discord/                # Discord integration
│   │   │       ├── client.ex           # Discord webhook HTTP client
│   │   │       └── message_builder.ex  # EVE-themed embed formatting
│   │   │
│   │   ├── optimization/               # Optimization domain
│   │   │   ├── optimization.ex         # Ash Domain
│   │   │   ├── engine.ex               # Main optimization coordinator
│   │   │   ├── solvers/
│   │   │   │   ├── heuristic.ex        # Greedy solver
│   │   │   │   └── constraint.ex       # Branch-and-bound solver
│   │   │   ├── constraints.ex          # Constraint definitions
│   │   │   └── types.ex                # ModuleCandidate, FittingSolution
│   │   │
│   │   └── fittings/                   # Ship fittings domain
│   │       ├── fittings.ex             # Ash Domain
│   │       ├── resources/
│   │       │   └── fitting.ex          # Saved fitting resource
│   │       ├── esi/
│   │       │   ├── client.ex           # ESI API client
│   │       │   └── oauth.ex            # EVE SSO OAuth2
│   │       └── parsers/
│   │           ├── eft.ex              # EFT format parser (enhanced)
│   │           ├── dna.ex              # DNA format parser/encoder
│   │           ├── xml.ex              # XML format parser
│   │           └── esi.ex              # ESI format converter
│   │
│   └── abyssalwatch_web/
│       ├── router.ex
│       ├── endpoint.ex
│       ├── channels/
│       │   ├── user_socket.ex
│       │   └── notification_channel.ex
│       ├── components/
│       │   ├── core_components.ex
│       │   ├── module_card.ex
│       │   ├── score_breakdown.ex
│       │   ├── filter_panel.ex
│       │   └── discord_settings.ex     # Discord notification settings UI
│       ├── live/
│       │   ├── dashboard_live.ex
│       │   ├── search_live.ex
│       │   ├── watchlist_live.ex
│       │   ├── optimization_live.ex
│       │   └── components/
│       │       ├── module_list.ex
│       │       ├── watchlist_form.ex
│       │       └── optimization_wizard.ex
│       └── controllers/
│           ├── auth_controller.ex
│           └── api/
│               └── webhook_controller.ex
│
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── prod.exs
│   ├── runtime.exs
│   └── test.exs
│
├── priv/
│   └── repo/
│       └── migrations/
│
├── test/
│   ├── abyssalwatch/
│   │   ├── market/
│   │   ├── watchlists/
│   │   └── optimization/
│   ├── abyssalwatch_web/
│   └── support/
│
└── assets/
    ├── css/
    └── js/
```

### Supervision Tree

```
AbyssalWatch.Application
├── AbyssalWatch.Repo
├── AbyssalWatchWeb.Endpoint
├── AbyssalWatch.Market.Mutamarket.Cache (ETS)
├── AbyssalWatch.Market.Mutamarket.RateLimiter
├── AbyssalWatch.Watchlists.Monitor (GenServer)
├── AbyssalWatch.NotificationTasks (Task.Supervisor)  # Async Discord notifications
└── Phoenix.PubSub
```

---

## 2. Technology Decisions

### Core Stack

| Component | Technology | Rationale |
|-----------|------------|-----------|
| Language | Elixir 1.16+ | Concurrency, fault tolerance, pattern matching |
| Framework | Phoenix 1.7+ | Mature web framework, excellent LiveView support |
| Data Layer | Ash Framework 3.x | Declarative resources, built-in actions, extensions |
| Database | PostgreSQL 16+ | JSON support, excellent indexing, familiar |
| Real-time | Phoenix LiveView | Server-rendered real-time UI, simpler than SPA |
| Background Jobs | GenServer | Simple enough for our needs, no external dependencies |
| Caching | ETS | In-memory, concurrent reads, built into Erlang |
| HTTP Client | Req | Modern, composable HTTP client |

### Key Libraries

```elixir
# mix.exs dependencies
defp deps do
  [
    # Core
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 0.20"},
    {:phoenix_html, "~> 4.0"},
    {:phoenix_live_reload, "~> 1.5", only: :dev},

    # Ash Framework
    {:ash, "~> 3.0"},
    {:ash_postgres, "~> 2.0"},
    {:ash_phoenix, "~> 2.0"},
    {:ash_authentication, "~> 4.0"},
    {:ash_authentication_phoenix, "~> 2.0"},

    # Database
    {:ecto_sql, "~> 3.11"},
    {:postgrex, "~> 0.17"},

    # HTTP
    {:req, "~> 0.5"},
    {:jason, "~> 1.4"},

    # Utilities
    {:decimal, "~> 2.1"},
    {:timex, "~> 3.7"},

    # Testing
    {:mox, "~> 1.1", only: :test},
    {:ex_machina, "~> 2.7", only: :test},

    # Dev tools
    {:credo, "~> 1.7", only: [:dev, :test]},
    {:dialyxir, "~> 1.4", only: [:dev, :test]}
  ]
end
```

### Architectural Patterns

1. **Ash Domains**: Each bounded context (Market, Watchlists, Optimization, Fittings) is an Ash Domain
2. **GenServer for Background Work**: Watchlist monitoring runs as a supervised GenServer
3. **ETS for Caching**: Module data cached in ETS with TTL management
4. **PubSub for Real-time**: Phoenix.PubSub for broadcasting updates to LiveView
5. **Behaviours for Extensibility**: Solver behaviour for swappable optimization strategies

---

## 3. Domain Model

### Entity Relationship Diagram

```
┌─────────────────┐       ┌─────────────────┐
│      User       │       │   ModuleType    │
├─────────────────┤       ├─────────────────┤
│ id              │       │ id              │
│ username        │       │ eve_type_id     │
│ password_hash   │       │ name            │
│ created_at      │       │ category        │
│ updated_at      │       │ slot_type       │
└──┬─────────┬────┘       │ base_attributes │
   │         │            └────────┬────────┘
   │         │                     │
   │ has_one │ has_many            │ has_many
   ▼         ▼                     ▼
┌───────────────────────┐  ┌─────────────────┐       ┌─────────────────┐
│ NotificationSettings  │  │   Watchlist     │       │     Module      │
├───────────────────────┤  ├─────────────────┤       ├─────────────────┤
│ id                    │  │ id              │       │ id (external)   │
│ user_id               │  │ user_id         │──────▶│ type_id         │
│ discord_webhook_url   │  │ module_type_id  │       │ name            │
│ discord_enabled       │  │ name            │       │ attributes      │ (JSONB)
│ discord_mention_role  │  │ important_attrs │(JSONB)│ price           │
│ min_score_threshold   │  │ unimportant_attr│(JSONB)│ score           │
│ max_notifs_per_hour   │  │ price_threshold │       │ source          │
│ quiet_hours_start     │  │ notifications_on│       │ available       │
│ quiet_hours_end       │  │ created_at      │       │ last_seen       │
│ created_at            │  │ updated_at      │       │ created_at      │
└───────────────────────┘  └────────┬────────┘       └─────────────────┘
                                    │
                                    │ has_many
                                    ▼
                           ┌─────────────────┐
                           │  Notification   │
                           ├─────────────────┤
                           │ id              │
                           │ user_id         │
                           │ watchlist_id    │
                           │ module_id       │
                           │ read            │
                           │ sent_at         │
                           └─────────────────┘


┌─────────────────┐
│    Fitting      │
├─────────────────┤
│ id              │
│ user_id         │
│ name            │
│ ship_type_id    │
│ modules         │ (JSONB)
│ constraints     │ (JSONB)
│ source          │
│ created_at      │
└─────────────────┘
```

### Ash Resource Definitions

#### Module Resource (Core)

```elixir
defmodule AbyssalWatch.Market.Module do
  use Ash.Resource,
    domain: AbyssalWatch.Market,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "modules"
    repo AbyssalWatch.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :external_id, :string, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :type_id, :integer, allow_nil?: false
    attribute :type_name, :string
    attribute :attributes, :map, default: %{}
    attribute :price, :decimal, default: 0
    attribute :score, :float, default: 0.0
    attribute :source, :string, default: "mutamarket"
    attribute :available, :boolean, default: true
    attribute :last_seen, :utc_datetime_usec

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    identity :external_id, [:external_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:external_id, :name, :type_id, :type_name, :attributes, :price, :source]
    end

    update :update do
      primary? true
      accept [:attributes, :price, :score, :available, :last_seen]
    end

    read :search do
      argument :type_id, :integer, allow_nil?: false
      argument :min_price, :decimal
      argument :max_price, :decimal
      argument :attribute_filters, {:array, :map}, default: []

      filter expr(type_id == ^arg(:type_id) and available == true)

      prepare fn query, _ ->
        # Dynamic attribute filtering applied here
        query
      end
    end

    read :by_type do
      argument :type_id, :integer, allow_nil?: false
      filter expr(type_id == ^arg(:type_id))
    end
  end

  calculations do
    calculate :efficiency, :float, expr(score / price) do
      filter expr(price > 0)
    end
  end
end
```

#### Watchlist Resource

```elixir
defmodule AbyssalWatch.Watchlists.Watchlist do
  use Ash.Resource,
    domain: AbyssalWatch.Watchlists,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "watchlists"
    repo AbyssalWatch.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false
    attribute :module_type_id, :integer, allow_nil?: false
    attribute :module_type_name, :string
    attribute :important_attributes, :map, default: %{}
    attribute :unimportant_attributes, :map, default: %{}
    attribute :price_threshold, :decimal
    attribute :notifications_enabled, :boolean, default: true

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, AbyssalWatch.Accounts.User, allow_nil?: false
    has_many :notifications, AbyssalWatch.Watchlists.Notification
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :module_type_id, :module_type_name,
              :important_attributes, :unimportant_attributes,
              :price_threshold, :notifications_enabled]

      change relate_actor(:user)
    end

    update :update do
      primary? true
      accept [:name, :important_attributes, :unimportant_attributes,
              :price_threshold, :notifications_enabled]
    end

    read :active do
      filter expr(notifications_enabled == true)
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end
  end

  validations do
    validate numericality(:price_threshold, greater_than_or_equal_to: 0),
      where: [present(:price_threshold)]
  end
end
```

---

## 4. Phase 1: Foundation & Module Search

### Objectives
- Set up project infrastructure
- Implement Mutamarket API integration
- Build TOPSIS scoring algorithm
- Create module search UI

### Tasks

#### 1.1 Project Setup
- [ ] Initialize Phoenix project with LiveView
- [ ] Configure Ash Framework
- [ ] Set up PostgreSQL database
- [ ] Configure development environment
- [ ] Set up testing infrastructure

#### 1.2 Session & Preferences (No User Accounts)
- [ ] Session-based preference storage (scoring presets, recent searches)
- [ ] Anonymous access to search and scoring features
- [ ] Prepare User resource schema for Phase 4 EVE SSO integration
- [ ] *Note: Full user accounts with EVE SSO added in Phase 4*

#### 1.3 Market Domain - Data Layer
- [ ] Create Module resource
- [ ] Create ModuleType resource
- [ ] Database migrations
- [ ] Seed module types (12 supported types)

#### 1.4 Mutamarket Integration
- [ ] HTTP client with Req
- [ ] Rate limiter (5 req/sec, 10-burst token bucket)
- [ ] ETS cache with 24-hour TTL
- [ ] Circuit breaker pattern
- [ ] Retry with exponential backoff

```elixir
defmodule AbyssalWatch.Market.Mutamarket.Client do
  @moduledoc """
  HTTP client for Mutamarket.com API
  """

  @base_url "https://mutamarket.com/api"

  def search_modules(type_id, opts \\ []) do
    with :ok <- RateLimiter.acquire(),
         {:ok, response} <- make_request("/modules/type/#{type_id}", opts) do
      {:ok, parse_modules(response.body)}
    end
  end

  def get_module(module_id) do
    with :ok <- RateLimiter.acquire(),
         {:ok, response} <- make_request("/modules/#{module_id}") do
      {:ok, parse_module(response.body)}
    end
  end

  defp make_request(path, opts \\ []) do
    Req.get(@base_url <> path,
      headers: [{"accept", "application/json"}],
      retry: :transient,
      max_retries: 3,
      retry_delay: &retry_delay/1
    )
  end

  defp retry_delay(attempt), do: min(30_000, 2_000 * :math.pow(2, attempt))
end
```

#### 1.5 TOPSIS Scoring Implementation

```elixir
defmodule AbyssalWatch.Market.Scoring.Topsis do
  @moduledoc """
  TOPSIS (Technique for Order of Preference by Similarity to Ideal Solution)
  multi-criteria decision-making algorithm.
  """

  alias AbyssalWatch.Market.Scoring.Criteria

  @type module_data :: %{
    id: String.t(),
    price: Decimal.t(),
    attributes: map()
  }

  @type scored_module :: %{
    module: module_data(),
    score: float(),
    breakdown: score_breakdown()
  }

  @doc """
  Apply TOPSIS scoring to a list of modules.

  ## Steps:
  1. Build decision matrix from module attributes
  2. Normalize matrix using vector normalization
  3. Apply criteria weights
  4. Determine ideal and anti-ideal solutions
  5. Calculate Euclidean distance to ideal/anti-ideal
  6. Compute relative closeness score
  """
  def score(modules, %Criteria{} = criteria) when is_list(modules) do
    modules
    |> build_decision_matrix(criteria)
    |> normalize_matrix()
    |> apply_weights(criteria)
    |> calculate_ideal_solutions(criteria)
    |> calculate_distances()
    |> calculate_closeness()
    |> rank_modules(modules)
  end

  defp build_decision_matrix(modules, criteria) do
    # Extract relevant attributes for each module
    # Returns matrix where rows = modules, cols = criteria
  end

  defp normalize_matrix(matrix) do
    # Vector normalization: x_ij / sqrt(sum(x_ij^2))
    for col <- transpose(matrix) do
      norm = :math.sqrt(Enum.sum(Enum.map(col, &(&1 * &1))))
      Enum.map(col, &(&1 / max(norm, 0.0001)))
    end
    |> transpose()
  end

  defp apply_weights(normalized, criteria) do
    weights = Criteria.to_weight_vector(criteria)

    for row <- normalized do
      Enum.zip(row, weights)
      |> Enum.map(fn {val, weight} -> val * weight end)
    end
  end

  defp calculate_ideal_solutions(weighted, criteria) do
    benefit_cols = Criteria.benefit_columns(criteria)

    ideal = for {col, idx} <- Enum.with_index(transpose(weighted)) do
      if idx in benefit_cols, do: Enum.max(col), else: Enum.min(col)
    end

    anti_ideal = for {col, idx} <- Enum.with_index(transpose(weighted)) do
      if idx in benefit_cols, do: Enum.min(col), else: Enum.max(col)
    end

    {weighted, ideal, anti_ideal}
  end

  defp calculate_distances({weighted, ideal, anti_ideal}) do
    for row <- weighted do
      d_plus = euclidean_distance(row, ideal)
      d_minus = euclidean_distance(row, anti_ideal)
      {d_plus, d_minus}
    end
  end

  defp euclidean_distance(a, b) do
    Enum.zip(a, b)
    |> Enum.map(fn {x, y} -> (x - y) * (x - y) end)
    |> Enum.sum()
    |> :math.sqrt()
  end

  defp calculate_closeness(distances) do
    Enum.map(distances, fn {d_plus, d_minus} ->
      d_minus / max(d_plus + d_minus, 0.0001)
    end)
  end

  defp rank_modules(scores, modules) do
    Enum.zip(modules, scores)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.map(fn {module, score} ->
      %{module: module, score: score}
    end)
  end
end
```

#### 1.6 Search LiveView

```elixir
defmodule AbyssalWatchWeb.SearchLive do
  use AbyssalWatchWeb, :live_view

  alias AbyssalWatch.Market
  alias AbyssalWatch.Market.Scoring.{Topsis, Criteria}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:module_types, Market.list_module_types())
     |> assign(:modules, [])
     |> assign(:loading, false)
     |> assign(:filters, default_filters())
     |> assign(:criteria, Criteria.default())}
  end

  @impl true
  def handle_event("search", %{"type_id" => type_id} = params, socket) do
    socket = assign(socket, :loading, true)
    send(self(), {:perform_search, type_id, params})
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_criteria", %{"criteria" => criteria_params}, socket) do
    criteria = Criteria.from_params(criteria_params)

    # Re-score existing modules with new criteria
    modules = Topsis.score(socket.assigns.raw_modules, criteria)

    {:noreply, assign(socket, criteria: criteria, modules: modules)}
  end

  @impl true
  def handle_info({:perform_search, type_id, params}, socket) do
    case Market.search_modules(type_id, build_filters(params)) do
      {:ok, raw_modules} ->
        scored = Topsis.score(raw_modules, socket.assigns.criteria)
        {:noreply,
         socket
         |> assign(:raw_modules, raw_modules)
         |> assign(:modules, scored)
         |> assign(:loading, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Search failed: #{reason}")
         |> assign(:loading, false)}
    end
  end
end
```

### Deliverables
- Working authentication system
- Module search with filters
- TOPSIS scoring with preset profiles
- Responsive LiveView UI
- Cached Mutamarket integration

---

## 5. Phase 2: Watchlists & Notifications

### Objectives
- Implement watchlist CRUD
- Background monitoring with GenServer
- Real-time notifications via PubSub
- **Discord webhook notifications for external alerts**
- Notification history and management
- User notification preferences configuration

### Tasks

#### 2.1 Watchlists Domain
- [ ] Create Watchlist resource
- [ ] Create Notification resource
- [ ] Database migrations
- [ ] CRUD actions with authorization

#### 2.2 Watchlist Monitor (GenServer)

```elixir
defmodule AbyssalWatch.Watchlists.Monitor do
  use GenServer

  alias AbyssalWatch.Watchlists
  alias AbyssalWatch.Watchlists.Matcher
  alias AbyssalWatch.Watchlists.Notifier

  @check_interval :timer.minutes(10)
  @max_concurrent 5

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{last_check: nil, stats: %{}}}
  end

  @impl true
  def handle_info(:check_watchlists, state) do
    Task.Supervisor.start_link(name: AbyssalWatch.WatchlistTasks)

    Watchlists.list_active()
    |> Stream.chunk_every(@max_concurrent)
    |> Enum.each(fn batch ->
      batch
      |> Enum.map(&Task.async(fn -> process_watchlist(&1) end))
      |> Task.await_many(30_000)
    end)

    schedule_check()
    {:noreply, %{state | last_check: DateTime.utc_now()}}
  end

  defp process_watchlist(watchlist) do
    with {:ok, modules} <- search_for_watchlist(watchlist),
         matches <- Matcher.find_matches(modules, watchlist),
         new_matches <- filter_notified(matches, watchlist) do

      if Enum.any?(new_matches) do
        Notifier.send(watchlist, new_matches)
        log_notifications(watchlist, new_matches)
      end
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_watchlists, @check_interval)
  end
end
```

#### 2.3 Matching Logic

```elixir
defmodule AbyssalWatch.Watchlists.Matcher do
  @moduledoc """
  Matches modules against watchlist criteria.
  """

  def find_matches(modules, watchlist) do
    modules
    |> Enum.filter(&matches_criteria?(&1, watchlist))
    |> Enum.map(&build_match(&1, watchlist))
  end

  defp matches_criteria?(module, watchlist) do
    matches_price?(module, watchlist) and
    matches_important_attrs?(module, watchlist) and
    not_exceeds_unimportant?(module, watchlist)
  end

  defp matches_price?(module, %{price_threshold: nil}), do: true
  defp matches_price?(module, %{price_threshold: threshold}) do
    Decimal.compare(module.price, threshold) != :gt
  end

  defp matches_important_attrs?(module, %{important_attributes: attrs}) do
    Enum.all?(attrs, fn {attr_name, min_value} ->
      case get_attribute(module, attr_name) do
        nil -> false
        value -> value >= min_value
      end
    end)
  end

  defp not_exceeds_unimportant?(module, %{unimportant_attributes: attrs}) do
    Enum.all?(attrs, fn {attr_name, max_value} ->
      case get_attribute(module, attr_name) do
        nil -> true
        value -> value <= max_value
      end
    end)
  end
end
```

#### 2.4 Real-time Notifications with PubSub

```elixir
defmodule AbyssalWatch.Watchlists.Notifier do
  alias Phoenix.PubSub

  @pubsub AbyssalWatch.PubSub

  def send(watchlist, matches) do
    payload = %{
      watchlist_id: watchlist.id,
      watchlist_name: watchlist.name,
      module_type: watchlist.module_type_name,
      matches: Enum.take(matches, 5),
      total_count: length(matches),
      sent_at: DateTime.utc_now()
    }

    # Broadcast to user's channel
    PubSub.broadcast(@pubsub, "user:#{watchlist.user_id}", {:new_matches, payload})
  end

  def subscribe(user_id) do
    PubSub.subscribe(@pubsub, "user:#{user_id}")
  end
end
```

#### 2.5 Watchlist LiveView

```elixir
defmodule AbyssalWatchWeb.WatchlistLive do
  use AbyssalWatchWeb, :live_view

  alias AbyssalWatch.Watchlists
  alias AbyssalWatch.Watchlists.Notifier

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Notifier.subscribe(user.id)
    end

    {:ok,
     socket
     |> assign(:watchlists, Watchlists.list_for_user(user.id))
     |> assign(:notifications, Watchlists.recent_notifications(user.id))}
  end

  @impl true
  def handle_info({:new_matches, payload}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "New matches for #{payload.watchlist_name}!")
     |> update(:notifications, &[payload | &1])}
  end
end
```

#### 2.6 Discord Webhook Integration

Discord notifications enable users to receive watchlist alerts outside the browser via Discord webhooks. Users can configure a personal webhook URL or use a server-wide webhook for corporation/alliance notifications.

##### 2.6.1 Discord Integration Tasks

- [ ] Create NotificationSettings resource for user preferences
- [ ] Create Discord.Client module for webhook HTTP requests
- [ ] Create Discord.MessageBuilder for EVE-themed embed formatting
- [ ] Create Discord.RateLimiter for webhook rate limit compliance
- [ ] Integrate Discord dispatch into Notifier module
- [ ] Add Discord settings UI to user preferences LiveView
- [ ] Add webhook URL validation (Discord webhook URL format)
- [ ] Implement retry logic with exponential backoff
- [ ] Add Discord notification toggle per watchlist
- [ ] Create notification delivery status tracking

##### 2.6.2 NotificationSettings Resource

```elixir
defmodule AbyssalWatch.Accounts.NotificationSettings do
  @moduledoc """
  User notification preferences including Discord webhook configuration.
  """

  use Ash.Resource,
    domain: AbyssalWatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "notification_settings"
    repo AbyssalWatch.Repo
  end

  attributes do
    uuid_primary_key :id

    # Discord Configuration
    attribute :discord_webhook_url, :string, sensitive?: true
    attribute :discord_enabled, :boolean, default: false
    attribute :discord_mention_role_id, :string  # Optional role to @mention

    # Notification Preferences
    attribute :min_score_threshold, :float, default: 0.0  # Only notify if score >= threshold
    attribute :max_notifications_per_hour, :integer, default: 10
    attribute :quiet_hours_start, :time  # Optional quiet hours (no notifications)
    attribute :quiet_hours_end, :time
    attribute :notify_on_price_drop, :boolean, default: true
    attribute :include_module_details, :boolean, default: true

    # Rate Limiting State
    attribute :discord_notifications_this_hour, :integer, default: 0
    attribute :discord_hour_window_start, :utc_datetime_usec

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, AbyssalWatch.Accounts.User, allow_nil?: false
  end

  identities do
    identity :user_id, [:user_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:discord_webhook_url, :discord_enabled, :discord_mention_role_id,
              :min_score_threshold, :max_notifications_per_hour,
              :quiet_hours_start, :quiet_hours_end, :notify_on_price_drop,
              :include_module_details]

      change relate_actor(:user)
    end

    update :update do
      primary? true
      accept [:discord_webhook_url, :discord_enabled, :discord_mention_role_id,
              :min_score_threshold, :max_notifications_per_hour,
              :quiet_hours_start, :quiet_hours_end, :notify_on_price_drop,
              :include_module_details]
    end

    update :increment_discord_count do
      change fn changeset, _ ->
        now = DateTime.utc_now()
        current_window = Ash.Changeset.get_attribute(changeset, :discord_hour_window_start)
        current_count = Ash.Changeset.get_attribute(changeset, :discord_notifications_this_hour)

        # Reset counter if we're in a new hour window
        if is_nil(current_window) or DateTime.diff(now, current_window, :hour) >= 1 do
          changeset
          |> Ash.Changeset.change_attribute(:discord_hour_window_start, now)
          |> Ash.Changeset.change_attribute(:discord_notifications_this_hour, 1)
        else
          Ash.Changeset.change_attribute(changeset, :discord_notifications_this_hour, current_count + 1)
        end
      end
    end
  end

  validations do
    validate match(:discord_webhook_url, ~r/^https:\/\/discord\.com\/api\/webhooks\/\d+\/[\w-]+$/),
      where: [present(:discord_webhook_url)],
      message: "must be a valid Discord webhook URL"
  end

  calculations do
    calculate :can_send_discord?, :boolean do
      calculation fn records, _ ->
        now = DateTime.utc_now()
        Enum.map(records, fn record ->
          cond do
            not record.discord_enabled -> false
            is_nil(record.discord_webhook_url) -> false
            in_quiet_hours?(record, now) -> false
            rate_limited?(record) -> false
            true -> true
          end
        end)
      end
    end
  end

  defp in_quiet_hours?(%{quiet_hours_start: nil}, _now), do: false
  defp in_quiet_hours?(%{quiet_hours_end: nil}, _now), do: false
  defp in_quiet_hours?(%{quiet_hours_start: start_time, quiet_hours_end: end_time}, now) do
    current_time = DateTime.to_time(now)
    Time.compare(current_time, start_time) != :lt and Time.compare(current_time, end_time) == :lt
  end

  defp rate_limited?(%{discord_hour_window_start: nil}), do: false
  defp rate_limited?(record) do
    now = DateTime.utc_now()
    if DateTime.diff(now, record.discord_hour_window_start, :hour) >= 1 do
      false  # New hour window, not rate limited
    else
      record.discord_notifications_this_hour >= record.max_notifications_per_hour
    end
  end
end
```

##### 2.6.3 Discord HTTP Client

```elixir
defmodule AbyssalWatch.Watchlists.Discord.Client do
  @moduledoc """
  HTTP client for Discord webhook API.

  Discord Webhook Rate Limits:
  - 30 requests per minute per webhook
  - 429 responses include Retry-After header

  Reference: https://discord.com/developers/docs/resources/webhook
  """

  require Logger

  @discord_api_version "10"
  @max_retries 3
  @base_retry_delay 1_000  # 1 second

  @type webhook_result :: {:ok, map()} | {:error, term()}

  @doc """
  Send a message to a Discord webhook.

  Options:
  - `:wait` - Wait for server confirmation (default: true)
  - `:thread_id` - Send to a specific thread
  """
  @spec send_webhook(String.t(), map(), keyword()) :: webhook_result()
  def send_webhook(webhook_url, payload, opts \\ []) do
    wait = Keyword.get(opts, :wait, true)
    thread_id = Keyword.get(opts, :thread_id)

    url = build_url(webhook_url, wait, thread_id)

    do_send_webhook(url, payload, 0)
  end

  defp do_send_webhook(url, payload, attempt) when attempt < @max_retries do
    case Req.post(url, json: payload, headers: headers()) do
      {:ok, %{status: status, body: body}} when status in [200, 204] ->
        Logger.debug("Discord webhook sent successfully")
        {:ok, body}

      {:ok, %{status: 429, headers: headers}} ->
        # Rate limited - extract retry-after and wait
        retry_after = get_retry_after(headers)
        Logger.warning("Discord rate limited, retrying after #{retry_after}ms")
        Process.sleep(retry_after)
        do_send_webhook(url, payload, attempt + 1)

      {:ok, %{status: status, body: body}} when status >= 400 ->
        Logger.error("Discord webhook failed: #{status} - #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("Discord webhook request failed: #{inspect(reason)}")
        # Retry with exponential backoff for network errors
        Process.sleep(backoff_delay(attempt))
        do_send_webhook(url, payload, attempt + 1)
    end
  end

  defp do_send_webhook(_url, _payload, _attempt) do
    {:error, :max_retries_exceeded}
  end

  defp build_url(webhook_url, wait, thread_id) do
    params = []
    params = if wait, do: [{"wait", "true"} | params], else: params
    params = if thread_id, do: [{"thread_id", thread_id} | params], else: params

    case params do
      [] -> webhook_url
      _ -> "#{webhook_url}?#{URI.encode_query(params)}"
    end
  end

  defp headers do
    [
      {"content-type", "application/json"},
      {"user-agent", "AbyssalWatch/1.0 (Elixir; +https://abyssalwatch.com)"}
    ]
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} ->
        case Float.parse(value) do
          {seconds, _} -> round(seconds * 1000)
          :error -> @base_retry_delay
        end
      nil ->
        @base_retry_delay
    end
  end

  defp backoff_delay(attempt) do
    # Exponential backoff: 1s, 2s, 4s
    @base_retry_delay * :math.pow(2, attempt) |> round()
  end

  @doc """
  Validate a Discord webhook URL format.
  """
  @spec valid_webhook_url?(String.t()) :: boolean()
  def valid_webhook_url?(url) when is_binary(url) do
    Regex.match?(~r/^https:\/\/discord\.com\/api\/webhooks\/\d+\/[\w-]+$/, url)
  end
  def valid_webhook_url?(_), do: false

  @doc """
  Test a webhook by sending a test message.
  Returns {:ok, :valid} if successful, {:error, reason} otherwise.
  """
  @spec test_webhook(String.t()) :: {:ok, :valid} | {:error, term()}
  def test_webhook(webhook_url) do
    test_payload = %{
      content: "✅ AbyssalWatch webhook test successful!",
      embeds: [
        %{
          title: "Webhook Connected",
          description: "This Discord channel will now receive watchlist notifications.",
          color: 0x00FF00,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ]
    }

    case send_webhook(webhook_url, test_payload) do
      {:ok, _} -> {:ok, :valid}
      error -> error
    end
  end
end
```

##### 2.6.4 Discord Message Builder

```elixir
defmodule AbyssalWatch.Watchlists.Discord.MessageBuilder do
  @moduledoc """
  Builds Discord embed messages for watchlist notifications.

  Uses EVE Online-themed styling with rich embeds containing:
  - Module details and attributes
  - Price and score information
  - Direct links to Mutamarket listings
  - Watchlist context
  """

  # EVE Online-inspired colors
  @color_success 0x00FF00      # Green - good match
  @color_warning 0xFFAA00      # Orange - moderate match
  @color_info 0x3498DB         # Blue - informational
  @color_eve_teal 0x30C5FF     # EVE UI teal

  @mutamarket_base_url "https://mutamarket.com/modules"

  @type match :: %{
    module: map(),
    score: float(),
    watchlist: map()
  }

  @doc """
  Build a Discord webhook payload for watchlist matches.
  """
  @spec build_notification(map(), [match()], keyword()) :: map()
  def build_notification(watchlist, matches, opts \\ []) do
    mention_role_id = Keyword.get(opts, :mention_role_id)
    include_details = Keyword.get(opts, :include_details, true)

    %{
      username: "AbyssalWatch",
      avatar_url: "https://abyssalwatch.com/images/logo.png",
      content: build_content(watchlist, matches, mention_role_id),
      embeds: build_embeds(watchlist, matches, include_details)
    }
  end

  @doc """
  Build a summary notification for multiple watchlist matches (digest mode).
  """
  @spec build_digest(list({map(), [match()]})) :: map()
  def build_digest(watchlist_matches) do
    total_matches = Enum.sum(Enum.map(watchlist_matches, fn {_, matches} -> length(matches) end))

    %{
      username: "AbyssalWatch",
      avatar_url: "https://abyssalwatch.com/images/logo.png",
      content: "📊 **Watchlist Digest**: #{total_matches} new matches across #{length(watchlist_matches)} watchlists",
      embeds: [build_digest_embed(watchlist_matches)]
    }
  end

  # Private Functions

  defp build_content(watchlist, matches, mention_role_id) do
    match_count = length(matches)
    mention = if mention_role_id, do: "<@&#{mention_role_id}> ", else: ""

    "#{mention}🔔 **#{match_count}** new module#{pluralize(match_count)} found for **#{watchlist.name}**!"
  end

  defp build_embeds(watchlist, matches, include_details) do
    # Main summary embed
    summary_embed = %{
      title: "#{watchlist.module_type_name} Matches",
      description: build_summary_description(watchlist),
      color: @color_eve_teal,
      thumbnail: %{
        url: module_type_icon_url(watchlist.module_type_id)
      },
      fields: build_summary_fields(matches),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      footer: %{
        text: "AbyssalWatch • Watchlist: #{watchlist.name}",
        icon_url: "https://abyssalwatch.com/images/icon-small.png"
      }
    }

    if include_details and length(matches) <= 3 do
      # Include detailed embeds for each module (max 3 to stay under Discord limits)
      detail_embeds = matches
        |> Enum.take(3)
        |> Enum.map(&build_module_embed/1)

      [summary_embed | detail_embeds]
    else
      [summary_embed]
    end
  end

  defp build_summary_description(watchlist) do
    criteria_parts = []

    criteria_parts = if watchlist.price_threshold do
      ["Max Price: **#{format_isk(watchlist.price_threshold)}**" | criteria_parts]
    else
      criteria_parts
    end

    criteria_parts = if map_size(watchlist.important_attributes) > 0 do
      attrs = watchlist.important_attributes
        |> Enum.map(fn {attr, min} -> "#{attr} ≥ #{min}" end)
        |> Enum.join(", ")
      ["Required: #{attrs}" | criteria_parts]
    else
      criteria_parts
    end

    case criteria_parts do
      [] -> "Modules matching your criteria are now available!"
      parts -> Enum.join(Enum.reverse(parts), "\n")
    end
  end

  defp build_summary_fields(matches) do
    best_match = Enum.max_by(matches, & &1.score, fn -> nil end)
    cheapest = Enum.min_by(matches, & &1.module.price, fn -> nil end)

    fields = [
      %{
        name: "📈 Matches Found",
        value: "#{length(matches)}",
        inline: true
      }
    ]

    fields = if best_match do
      [%{
        name: "🏆 Best Score",
        value: "#{Float.round(best_match.score * 100, 1)}%",
        inline: true
      } | fields]
    else
      fields
    end

    fields = if cheapest do
      [%{
        name: "💰 Lowest Price",
        value: format_isk(cheapest.module.price),
        inline: true
      } | fields]
    else
      fields
    end

    # Add link to view all matches
    fields ++ [
      %{
        name: "🔗 View Matches",
        value: "[Open in AbyssalWatch](https://abyssalwatch.com/search?type=#{best_match.module.type_id})",
        inline: false
      }
    ]
  end

  defp build_module_embed(match) do
    module = match.module
    score_color = score_to_color(match.score)

    %{
      title: module.name,
      url: "#{@mutamarket_base_url}/#{module.external_id}",
      color: score_color,
      fields: build_module_fields(module, match.score),
      thumbnail: %{
        url: module_type_icon_url(module.type_id)
      }
    }
  end

  defp build_module_fields(module, score) do
    # Core fields
    fields = [
      %{name: "💰 Price", value: format_isk(module.price), inline: true},
      %{name: "📊 Score", value: "#{Float.round(score * 100, 1)}%", inline: true},
      %{name: "📦 ID", value: "`#{module.external_id}`", inline: true}
    ]

    # Add key attributes (limit to 6 to avoid embed size limits)
    attr_fields = module.attributes
      |> Enum.take(6)
      |> Enum.map(fn {attr_name, value} ->
        %{
          name: format_attribute_name(attr_name),
          value: format_attribute_value(attr_name, value),
          inline: true
        }
      end)

    fields ++ attr_fields
  end

  defp build_digest_embed(watchlist_matches) do
    fields = watchlist_matches
      |> Enum.take(10)  # Limit to 10 watchlists in digest
      |> Enum.map(fn {watchlist, matches} ->
        best_score = matches |> Enum.map(& &1.score) |> Enum.max(fn -> 0 end)
        %{
          name: watchlist.name,
          value: "#{length(matches)} matches (best: #{Float.round(best_score * 100, 1)}%)",
          inline: true
        }
      end)

    %{
      title: "Watchlist Summary",
      color: @color_info,
      fields: fields,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      footer: %{
        text: "AbyssalWatch Digest"
      }
    }
  end

  # Helper Functions

  defp score_to_color(score) when score >= 0.8, do: @color_success
  defp score_to_color(score) when score >= 0.5, do: @color_warning
  defp score_to_color(_), do: @color_info

  defp format_isk(nil), do: "N/A"
  defp format_isk(price) do
    price
    |> Decimal.to_float()
    |> format_number()
    |> Kernel.<>(" ISK")
  end

  defp format_number(num) when num >= 1_000_000_000 do
    "#{Float.round(num / 1_000_000_000, 2)}B"
  end
  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 2)}M"
  end
  defp format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end
  defp format_number(num), do: "#{round(num)}"

  defp format_attribute_name(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_attribute_value(attr_name, value) when is_float(value) do
    cond do
      String.contains?(attr_name, "percent") -> "#{Float.round(value, 1)}%"
      String.contains?(attr_name, "duration") -> "#{Float.round(value / 1000, 2)}s"
      true -> "#{Float.round(value, 2)}"
    end
  end
  defp format_attribute_value(_attr_name, value), do: "#{value}"

  defp module_type_icon_url(type_id) do
    "https://images.evetech.net/types/#{type_id}/icon?size=64"
  end

  defp pluralize(1), do: ""
  defp pluralize(_), do: "s"
end
```

##### 2.6.5 Updated Notifier with Discord Integration

```elixir
defmodule AbyssalWatch.Watchlists.Notifier do
  @moduledoc """
  Notification dispatcher for watchlist matches.

  Supports multiple notification channels:
  - Phoenix.PubSub (real-time LiveView updates)
  - Discord webhooks (external notifications)
  - Future: Email, Push notifications
  """

  alias Phoenix.PubSub
  alias AbyssalWatch.Watchlists.Discord.{Client, MessageBuilder}
  alias AbyssalWatch.Accounts.NotificationSettings

  require Logger

  @pubsub AbyssalWatch.PubSub

  @doc """
  Send notifications for watchlist matches through all enabled channels.
  """
  def send(watchlist, matches) do
    payload = build_payload(watchlist, matches)

    # Always send to PubSub for real-time UI updates
    send_pubsub(watchlist.user_id, payload)

    # Send to Discord if enabled
    send_discord_async(watchlist, matches)

    :ok
  end

  @doc """
  Subscribe to real-time notifications for a user.
  """
  def subscribe(user_id) do
    PubSub.subscribe(@pubsub, "user:#{user_id}")
  end

  # Private Functions

  defp build_payload(watchlist, matches) do
    %{
      watchlist_id: watchlist.id,
      watchlist_name: watchlist.name,
      module_type: watchlist.module_type_name,
      matches: Enum.take(matches, 5),
      total_count: length(matches),
      sent_at: DateTime.utc_now()
    }
  end

  defp send_pubsub(user_id, payload) do
    PubSub.broadcast(@pubsub, "user:#{user_id}", {:new_matches, payload})
  end

  defp send_discord_async(watchlist, matches) do
    # Run Discord notification in a separate task to avoid blocking
    Task.Supervisor.start_child(AbyssalWatch.NotificationTasks, fn ->
      send_discord(watchlist, matches)
    end)
  end

  defp send_discord(watchlist, matches) do
    with {:ok, settings} <- get_notification_settings(watchlist.user_id),
         true <- should_send_discord?(settings, matches),
         {:ok, _} <- do_send_discord(watchlist, matches, settings) do

      # Update rate limit counter
      increment_discord_counter(settings)
      Logger.info("Discord notification sent for watchlist #{watchlist.id}")
    else
      {:ok, :skipped} ->
        Logger.debug("Discord notification skipped for watchlist #{watchlist.id}")

      {:error, reason} ->
        Logger.warning("Discord notification failed for watchlist #{watchlist.id}: #{inspect(reason)}")
    end
  end

  defp get_notification_settings(user_id) do
    case AbyssalWatch.Accounts.get_notification_settings(user_id) do
      nil -> {:error, :no_settings}
      settings -> {:ok, settings}
    end
  end

  defp should_send_discord?(settings, matches) do
    cond do
      not settings.discord_enabled ->
        false

      is_nil(settings.discord_webhook_url) ->
        false

      in_quiet_hours?(settings) ->
        false

      rate_limited?(settings) ->
        Logger.debug("Discord rate limited for user, skipping notification")
        false

      # Check minimum score threshold
      settings.min_score_threshold > 0 ->
        Enum.any?(matches, fn match ->
          match.score >= settings.min_score_threshold
        end)

      true ->
        true
    end
  end

  defp do_send_discord(watchlist, matches, settings) do
    payload = MessageBuilder.build_notification(
      watchlist,
      matches,
      mention_role_id: settings.discord_mention_role_id,
      include_details: settings.include_module_details
    )

    Client.send_webhook(settings.discord_webhook_url, payload)
  end

  defp increment_discord_counter(settings) do
    AbyssalWatch.Accounts.increment_discord_notification_count(settings.id)
  end

  defp in_quiet_hours?(%{quiet_hours_start: nil}), do: false
  defp in_quiet_hours?(%{quiet_hours_end: nil}), do: false
  defp in_quiet_hours?(%{quiet_hours_start: start_time, quiet_hours_end: end_time}) do
    current_time = DateTime.utc_now() |> DateTime.to_time()
    Time.compare(current_time, start_time) != :lt and
    Time.compare(current_time, end_time) == :lt
  end

  defp rate_limited?(%{discord_hour_window_start: nil}), do: false
  defp rate_limited?(settings) do
    now = DateTime.utc_now()
    if DateTime.diff(now, settings.discord_hour_window_start, :hour) >= 1 do
      false
    else
      settings.discord_notifications_this_hour >= settings.max_notifications_per_hour
    end
  end
end
```

##### 2.6.6 Discord Settings LiveView Component

```elixir
defmodule AbyssalWatchWeb.Components.DiscordSettings do
  @moduledoc """
  LiveView component for Discord notification settings.
  """

  use AbyssalWatchWeb, :live_component

  alias AbyssalWatch.Watchlists.Discord.Client

  @impl true
  def render(assigns) do
    ~H"""
    <div class="discord-settings">
      <h3 class="text-lg font-semibold mb-4">Discord Notifications</h3>

      <.form for={@form} phx-submit="save_discord" phx-change="validate_discord" phx-target={@myself}>
        <div class="space-y-4">
          <!-- Enable Toggle -->
          <div class="flex items-center justify-between">
            <label class="font-medium">Enable Discord Notifications</label>
            <.input type="checkbox" field={@form[:discord_enabled]} />
          </div>

          <!-- Webhook URL -->
          <div>
            <label class="block font-medium mb-1">Webhook URL</label>
            <.input
              type="text"
              field={@form[:discord_webhook_url]}
              placeholder="https://discord.com/api/webhooks/..."
              class="w-full"
            />
            <p class="text-sm text-gray-500 mt-1">
              <a href="https://support.discord.com/hc/en-us/articles/228383668"
                 target="_blank" class="text-blue-500 hover:underline">
                How to create a Discord webhook
              </a>
            </p>
          </div>

          <!-- Test Button -->
          <div>
            <button
              type="button"
              phx-click="test_webhook"
              phx-target={@myself}
              disabled={is_nil(@form[:discord_webhook_url].value)}
              class="btn btn-secondary"
            >
              Test Webhook
            </button>
            <%= if @test_result do %>
              <span class={[
                "ml-2",
                @test_result == :success && "text-green-500",
                @test_result == :error && "text-red-500"
              ]}>
                <%= if @test_result == :success, do: "✓ Webhook working!", else: "✗ Test failed" %>
              </span>
            <% end %>
          </div>

          <!-- Optional: Role Mention -->
          <div>
            <label class="block font-medium mb-1">Role to Mention (Optional)</label>
            <.input
              type="text"
              field={@form[:discord_mention_role_id]}
              placeholder="Role ID (e.g., 123456789012345678)"
            />
            <p class="text-sm text-gray-500 mt-1">
              Enable Developer Mode in Discord, right-click a role, and copy ID
            </p>
          </div>

          <!-- Notification Preferences -->
          <div class="border-t pt-4 mt-4">
            <h4 class="font-medium mb-3">Notification Preferences</h4>

            <div class="space-y-3">
              <div>
                <label class="block text-sm mb-1">Minimum Score Threshold</label>
                <.input
                  type="range"
                  field={@form[:min_score_threshold]}
                  min="0"
                  max="1"
                  step="0.1"
                />
                <span class="text-sm"><%= Float.round((@form[:min_score_threshold].value || 0) * 100, 0) %>%</span>
              </div>

              <div>
                <label class="block text-sm mb-1">Max Notifications Per Hour</label>
                <.input
                  type="number"
                  field={@form[:max_notifications_per_hour]}
                  min="1"
                  max="60"
                />
              </div>

              <div class="flex items-center gap-2">
                <.input type="checkbox" field={@form[:include_module_details]} />
                <label class="text-sm">Include detailed module information</label>
              </div>
            </div>
          </div>

          <!-- Quiet Hours -->
          <div class="border-t pt-4 mt-4">
            <h4 class="font-medium mb-3">Quiet Hours (No Notifications)</h4>
            <div class="flex gap-4">
              <div>
                <label class="block text-sm mb-1">Start</label>
                <.input type="time" field={@form[:quiet_hours_start]} />
              </div>
              <div>
                <label class="block text-sm mb-1">End</label>
                <.input type="time" field={@form[:quiet_hours_end]} />
              </div>
            </div>
          </div>

          <div class="pt-4">
            <button type="submit" class="btn btn-primary">Save Discord Settings</button>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def mount(socket) do
    {:ok, assign(socket, test_result: nil)}
  end

  @impl true
  def handle_event("test_webhook", _, socket) do
    webhook_url = socket.assigns.form[:discord_webhook_url].value

    result = case Client.test_webhook(webhook_url) do
      {:ok, :valid} -> :success
      {:error, _} -> :error
    end

    {:noreply, assign(socket, test_result: result)}
  end

  @impl true
  def handle_event("validate_discord", %{"notification_settings" => params}, socket) do
    # Validate form
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_discord", %{"notification_settings" => params}, socket) do
    # Save settings via parent LiveView
    send(self(), {:save_discord_settings, params})
    {:noreply, socket}
  end
end
```

### Deliverables
- Watchlist CRUD with LiveView forms
- Background monitoring GenServer
- Real-time notification delivery (PubSub)
- **Discord webhook integration with EVE-themed embeds**
- **User notification preferences configuration**
- **Discord rate limiting and quiet hours**
- Notification history with read/unread status
- 24-hour deduplication

---

## 6. Phase 3: Optimization Engine

### Objectives
- Implement heuristic (greedy) solver
- Implement branch-and-bound solver
- Build optimization wizard UI
- Solution comparison and export

### Tasks

#### 3.1 Optimization Types

```elixir
defmodule AbyssalWatch.Optimization.Types do
  @moduledoc """
  Type definitions for the optimization engine.
  """

  defmodule ModuleCandidate do
    @type t :: %__MODULE__{
      id: String.t(),
      type_id: integer(),
      slot_type: :high | :med | :low | :rig,
      name: String.t(),
      cpu_usage: float(),
      power_usage: float(),
      calibration_usage: float(),
      price: Decimal.t(),
      score: float(),
      efficiency: float(),
      attributes: map()
    }

    defstruct [:id, :type_id, :slot_type, :name, :cpu_usage, :power_usage,
               :calibration_usage, :price, :score, :efficiency, :attributes]
  end

  defmodule Constraints do
    @type t :: %__MODULE__{
      cpu_capacity: float(),
      power_capacity: float(),
      calibration_capacity: float(),
      available_slots: %{
        high: non_neg_integer(),
        med: non_neg_integer(),
        low: non_neg_integer(),
        rig: non_neg_integer()
      },
      max_price: Decimal.t() | nil
    }

    defstruct [:cpu_capacity, :power_capacity, :calibration_capacity,
               :available_slots, :max_price]
  end

  defmodule Solution do
    @type t :: %__MODULE__{
      id: String.t(),
      rank: non_neg_integer(),
      modules: [ModuleCandidate.t()],
      total_score: float(),
      total_price: Decimal.t(),
      efficiency: float(),
      resource_usage: resource_usage(),
      score_breakdown: map()
    }

    defstruct [:id, :rank, :modules, :total_score, :total_price,
               :efficiency, :resource_usage, :score_breakdown]
  end
end
```

#### 3.2 Heuristic Solver

```elixir
defmodule AbyssalWatch.Optimization.Solvers.Heuristic do
  @moduledoc """
  Greedy heuristic solver for ship fitting optimization.

  Algorithm:
  1. Calculate efficiency (score/price) for all candidates
  2. Sort by efficiency descending
  3. Greedily select modules that satisfy constraints
  4. Generate alternative solutions (budget, balanced)
  """

  alias AbyssalWatch.Optimization.Types.{ModuleCandidate, Constraints, Solution}

  def solve(candidates, %Constraints{} = constraints, opts \\ []) do
    sorted = sort_by_efficiency(candidates)

    primary = greedy_select(sorted, constraints, %{
      cpu: 0, power: 0, calibration: 0,
      slots: %{high: 0, med: 0, low: 0, rig: 0},
      price: Decimal.new(0)
    })

    alternatives = [
      generate_budget_solution(sorted, constraints),
      generate_balanced_solution(candidates, constraints)
    ]

    [primary | alternatives]
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {solution, rank} -> %{solution | rank: rank} end)
  end

  defp sort_by_efficiency(candidates) do
    Enum.sort_by(candidates, & &1.efficiency, :desc)
  end

  defp greedy_select([], _constraints, state), do: build_solution(state)
  defp greedy_select([candidate | rest], constraints, state) do
    if can_add?(candidate, constraints, state) do
      new_state = add_module(candidate, state)
      greedy_select(rest, constraints, new_state)
    else
      greedy_select(rest, constraints, state)
    end
  end

  defp can_add?(candidate, constraints, state) do
    state.cpu + candidate.cpu_usage <= constraints.cpu_capacity and
    state.power + candidate.power_usage <= constraints.power_capacity and
    state.calibration + candidate.calibration_usage <= constraints.calibration_capacity and
    state.slots[candidate.slot_type] < constraints.available_slots[candidate.slot_type] and
    (is_nil(constraints.max_price) or
     Decimal.add(state.price, candidate.price) |> Decimal.compare(constraints.max_price) != :gt)
  end
end
```

#### 3.3 Branch-and-Bound Solver

```elixir
defmodule AbyssalWatch.Optimization.Solvers.Constraint do
  @moduledoc """
  Branch-and-bound constraint solver for optimal solutions.

  Explores solution space systematically with pruning.
  More thorough than heuristic but slower.
  """

  @max_solutions 100
  @prune_threshold 0.90  # Prune if < 90% of best

  def solve(candidates, constraints, opts \\ []) do
    grouped = Enum.group_by(candidates, & &1.slot_type)

    initial_state = %{
      modules: [],
      cpu: 0, power: 0, calibration: 0,
      slots: %{high: 0, med: 0, low: 0, rig: 0},
      price: Decimal.new(0),
      score: 0
    }

    solutions =
      explore(grouped, constraints, initial_state, [], 0)
      |> Enum.sort_by(& &1.total_score, :desc)
      |> Enum.take(@max_solutions)
      |> diversify_solutions()

    solutions
    |> Enum.with_index(1)
    |> Enum.map(fn {sol, rank} -> %{sol | rank: rank} end)
  end

  defp explore(_grouped, _constraints, state, solutions, _best)
       when length(solutions) >= @max_solutions do
    solutions
  end

  defp explore(grouped, constraints, state, solutions, best_score) do
    if should_prune?(state, best_score) do
      solutions
    else
      # Try adding a module from each slot type
      Enum.reduce(Map.keys(grouped), solutions, fn slot_type, acc ->
        candidates = Map.get(grouped, slot_type, [])

        Enum.reduce(candidates, acc, fn candidate, inner_acc ->
          if can_add?(candidate, constraints, state) do
            new_state = add_module(candidate, state)

            if is_complete?(new_state, constraints) do
              solution = build_solution(new_state)
              new_best = max(best_score, solution.total_score)
              explore(grouped, constraints, new_state, [solution | inner_acc], new_best)
            else
              explore(grouped, constraints, new_state, inner_acc, best_score)
            end
          else
            inner_acc
          end
        end)
      end)
    end
  end

  defp should_prune?(state, best_score) when best_score > 0 do
    # Estimate upper bound of achievable score
    state.score / best_score < @prune_threshold
  end
  defp should_prune?(_, _), do: false

  defp diversify_solutions(solutions) do
    # Ensure variety by selecting solutions with different module combinations
    solutions
    |> Enum.uniq_by(fn sol ->
      sol.modules |> Enum.map(& &1.id) |> Enum.sort()
    end)
  end
end
```

#### 3.4 Optimization Engine Coordinator

```elixir
defmodule AbyssalWatch.Optimization.Engine do
  @moduledoc """
  Main coordination point for ship fitting optimization.
  """

  alias AbyssalWatch.Optimization.Solvers.{Heuristic, Constraint}
  alias AbyssalWatch.Optimization.Types.{Constraints, Solution}

  @type solver_mode :: :heuristic | :constraint

  def optimize(candidates, constraints, opts \\ []) do
    mode = Keyword.get(opts, :mode, :heuristic)

    with :ok <- validate_request(candidates, constraints) do
      solutions =
        case mode do
          :heuristic -> Heuristic.solve(candidates, constraints, opts)
          :constraint -> Constraint.solve(candidates, constraints, opts)
        end

      {:ok, %{
        solutions: solutions,
        mode: mode,
        solved_at: DateTime.utc_now(),
        candidate_count: length(candidates)
      }}
    end
  end

  defp validate_request(candidates, constraints) do
    cond do
      Enum.empty?(candidates) ->
        {:error, "No module candidates provided"}
      constraints.cpu_capacity <= 0 ->
        {:error, "CPU capacity must be positive"}
      constraints.power_capacity <= 0 ->
        {:error, "Power capacity must be positive"}
      Enum.all?(Map.values(constraints.available_slots), &(&1 == 0)) ->
        {:error, "At least one slot type must be available"}
      true ->
        :ok
    end
  end
end
```

#### 3.5 Optimization Wizard LiveView

```elixir
defmodule AbyssalWatchWeb.OptimizationLive do
  use AbyssalWatchWeb, :live_view

  alias AbyssalWatch.Optimization.Engine
  alias AbyssalWatch.Market

  @steps [:import, :constraints, :objectives, :optimize, :results]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:step, :import)
     |> assign(:fitting, nil)
     |> assign(:constraints, nil)
     |> assign(:criteria, nil)
     |> assign(:solutions, [])
     |> assign(:optimizing, false)}
  end

  @impl true
  def handle_event("import_eft", %{"eft" => eft_text}, socket) do
    case parse_eft(eft_text) do
      {:ok, fitting} ->
        {:noreply, socket |> assign(:fitting, fitting) |> assign(:step, :constraints)}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("set_constraints", params, socket) do
    constraints = build_constraints(params)
    {:noreply, socket |> assign(:constraints, constraints) |> assign(:step, :objectives)}
  end

  @impl true
  def handle_event("run_optimization", %{"mode" => mode}, socket) do
    socket = assign(socket, :optimizing, true)
    send(self(), {:run_optimization, String.to_atom(mode)})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_optimization, mode}, socket) do
    candidates = fetch_candidates(socket.assigns.fitting)

    case Engine.optimize(candidates, socket.assigns.constraints, mode: mode) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:solutions, result.solutions)
         |> assign(:step, :results)
         |> assign(:optimizing, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, reason)
         |> assign(:optimizing, false)}
    end
  end
end
```

### Deliverables
- Heuristic greedy solver
- Branch-and-bound constraint solver
- Multi-step optimization wizard
- Solution comparison UI
- EFT format export

---

## 7. Phase 4: ESI Integration & Advanced Fitting Formats

### Objectives
- Implement EVE SSO OAuth2
- Fetch character fittings from ESI
- Import fittings into optimizer
- Export optimized fits
- Support all official EVE fitting formats (EFT, DNA, XML)
- Enable in-game chat link generation
- Provide shareable fitting URLs

### Reference
EVE Developer Documentation: https://developers.eveonline.com/docs/guides/fitting/

### Tasks

#### 4.0 Phase 4 Checklist

**EVE SSO Authentication (Primary Auth)**
- [ ] Implement EVE SSO OAuth2 as primary authentication method
- [ ] Create/update User resource with EVE character data (character_id, character_name)
- [ ] Store refresh tokens securely for ESI access
- [ ] Implement login/logout flow with EVE SSO
- [ ] Migrate any session-based data to user accounts
- [ ] Protected routes requiring EVE SSO authentication

**ESI Integration**
- [ ] Create ESI client for fittings API
- [ ] Fetch character fittings from ESI
- [ ] Handle token refresh automatically

**Advanced Fitting Formats**
- [ ] Enhanced EFT parser (offline notation, quantities, empty slots, sections)
- [ ] DNA format parser and encoder
- [ ] In-game chat link generation (`<url=fitting:...>`)
- [ ] Shareable fitting URLs
- [ ] XML format parser for file import
- [ ] XML format encoder for file export
- [ ] Update Fitting resource with DNA storage and calculations
- [ ] Add fitting import LiveView routes
- [ ] Add "Copy In-Game Link" button to optimization results
- [ ] Add "Share URL" functionality

#### 4.1 EVE SSO OAuth2 (Primary Authentication)

```elixir
defmodule AbyssalWatch.Accounts.EVEAuth do
  @moduledoc """
  EVE SSO OAuth2 implementation - Primary authentication for AbyssalWatch.

  Users authenticate with their EVE Online account, providing:
  - Character identity (name, ID, portrait)
  - Access to ESI endpoints (fittings, etc.)
  - No separate password management needed
  """

  @authorize_url "https://login.eveonline.com/v2/oauth/authorize"
  @token_url "https://login.eveonline.com/v2/oauth/token"
  @verify_url "https://esi.evetech.net/verify/"

  # Scopes for authentication and ESI access
  @scopes [
    "publicData",                           # Basic character info
    "esi-fittings.read_fittings.v1",       # Read character fittings
    "esi-fittings.write_fittings.v1"       # Save fittings to character
  ]

  def authorize_url(state) do
    params = %{
      response_type: "code",
      redirect_uri: callback_url(),
      client_id: client_id(),
      scope: Enum.join(@scopes, " "),
      state: state
    }

    "#{@authorize_url}?#{URI.encode_query(params)}"
  end

  def exchange_code(code) do
    Req.post(@token_url,
      form: [
        grant_type: "authorization_code",
        code: code
      ],
      auth: {:basic, {client_id(), client_secret()}}
    )
    |> handle_token_response()
  end

  def refresh_token(refresh_token) do
    Req.post(@token_url,
      form: [
        grant_type: "refresh_token",
        refresh_token: refresh_token
      ],
      auth: {:basic, {client_id(), client_secret()}}
    )
    |> handle_token_response()
  end

  @doc """
  Verify token and get character information.
  Returns character_id, character_name, and other identity info.
  """
  def verify_character(access_token) do
    case Req.get(@verify_url, headers: [{"authorization", "Bearer #{access_token}"}]) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{
          character_id: body["CharacterID"],
          character_name: body["CharacterName"],
          expires_on: body["ExpiresOn"],
          scopes: body["Scopes"]
        }}
      {:ok, %{status: status}} ->
        {:error, "Verification failed with status #{status}"}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

#### 4.2 User Resource with EVE Character Data

```elixir
defmodule AbyssalWatch.Accounts.User do
  @moduledoc """
  User resource linked to EVE Online character via SSO.
  """

  use Ash.Resource,
    domain: AbyssalWatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo AbyssalWatch.Repo
  end

  attributes do
    uuid_primary_key :id

    # EVE Character Identity
    attribute :character_id, :integer, allow_nil?: false
    attribute :character_name, :string, allow_nil?: false
    attribute :character_portrait_url, :string

    # OAuth Tokens (encrypted at rest)
    attribute :access_token, :string, sensitive?: true
    attribute :refresh_token, :string, sensitive?: true
    attribute :token_expires_at, :utc_datetime_usec

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :last_login_at, :utc_datetime_usec
  end

  identities do
    identity :character_id, [:character_id]
  end

  relationships do
    has_many :watchlists, AbyssalWatch.Watchlists.Watchlist
    has_many :fittings, AbyssalWatch.Fittings.Fitting
    has_many :notifications, AbyssalWatch.Watchlists.Notification
  end

  actions do
    defaults [:read]

    create :from_eve_sso do
      accept [:character_id, :character_name, :access_token, :refresh_token, :token_expires_at]

      upsert? true
      upsert_identity :character_id
      upsert_fields [:character_name, :access_token, :refresh_token, :token_expires_at, :last_login_at]

      change set_attribute(:last_login_at, &DateTime.utc_now/0)
    end

    update :refresh_tokens do
      accept [:access_token, :refresh_token, :token_expires_at]
    end
  end

  calculations do
    calculate :token_expired?, :boolean do
      calculation fn records, _ ->
        now = DateTime.utc_now()
        Enum.map(records, fn record ->
          case record.token_expires_at do
            nil -> true
            expires_at -> DateTime.compare(expires_at, now) == :lt
          end
        end)
      end
    end
  end
end
```

#### 4.3 ESI Fittings Client

```elixir
defmodule AbyssalWatch.Fittings.ESI.Client do
  @moduledoc """
  ESI API client for ship fittings.
  """

  @base_url "https://esi.evetech.net/latest"

  def get_fittings(character_id, access_token) do
    Req.get("#{@base_url}/characters/#{character_id}/fittings/",
      headers: [{"authorization", "Bearer #{access_token}"}]
    )
    |> handle_response()
  end

  def get_ship_type(type_id) do
    Req.get("#{@base_url}/universe/types/#{type_id}/")
    |> handle_response()
  end

  def create_fitting(character_id, fitting, access_token) do
    Req.post("#{@base_url}/characters/#{character_id}/fittings/",
      json: fitting,
      headers: [{"authorization", "Bearer #{access_token}"}]
    )
    |> handle_response()
  end
end
```

#### 4.4 Enhanced EFT Parser

```elixir
defmodule AbyssalWatch.Fittings.Parsers.EFT do
  @moduledoc """
  Enhanced parser for EVE Fitting Tool (EFT) format.

  Supports official EFT format features:
  - [Ship, Name] header
  - Module sections separated by blank lines (low → med → high → rigs → subsystems → drones → cargo)
  - Empty slot markers: [Empty Low slot], [Empty Med slot], etc.
  - Quantity suffixes: x## (e.g., "Hobgoblin II x5")
  - Offline notation: /offline suffix (stripped on import)
  - Localized type names

  Example format:
  [Vexor Navy Issue, PvP Fit]
  Damage Control II
  Drone Damage Amplifier II

  10MN Afterburner II
  Warp Scrambler II

  Hobgoblin II x5
  """

  @empty_slot_pattern ~r/^\[Empty\s+(\w+)\s+slot\]$/i
  @quantity_pattern ~r/^(.+?)\s+x(\d+)$/
  @offline_pattern ~r/\s*\/offline$/i

  def parse(eft_text) do
    lines = String.split(eft_text, "\n")

    with {:ok, {ship_type, fit_name}} <- parse_header(List.first(lines)),
         {:ok, sections} <- parse_sections(Enum.drop(lines, 1)) do
      {:ok, %{
        ship_type: ship_type,
        name: fit_name,
        low_slots: sections.low,
        med_slots: sections.med,
        high_slots: sections.high,
        rig_slots: sections.rig,
        subsystems: sections.subsystem,
        drones: sections.drone,
        cargo: sections.cargo,
        modules: flatten_modules(sections)
      }}
    end
  end

  def encode(fitting) do
    """
    [#{fitting.ship_type}, #{fitting.name}]

    #{encode_section(fitting.low_slots)}

    #{encode_section(fitting.med_slots)}

    #{encode_section(fitting.high_slots)}

    #{encode_section(fitting.rig_slots)}

    #{encode_section(fitting.drones)}

    #{encode_section(fitting.cargo)}
    """
    |> String.trim()
  end

  defp parse_header(line) do
    case Regex.run(~r/^\[(.+),\s*(.+)\]$/, String.trim(line)) do
      [_, ship_type, fit_name] -> {:ok, {ship_type, String.trim(fit_name)}}
      _ -> {:error, "Invalid EFT header format"}
    end
  end

  defp parse_sections(lines) do
    # Split by blank lines into sections
    sections =
      lines
      |> Enum.chunk_by(&(String.trim(&1) == ""))
      |> Enum.reject(&(Enum.all?(&1, fn l -> String.trim(l) == "" end)))
      |> Enum.map(&parse_section/1)

    # Assign sections by order: low, med, high, rigs, subsystems, drones, cargo
    {:ok, assign_sections(sections)}
  end

  defp parse_section(lines) do
    lines
    |> Enum.map(&parse_module_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_module_line(line) do
    line = line |> String.trim() |> strip_offline()

    cond do
      String.trim(line) == "" -> nil
      Regex.match?(@empty_slot_pattern, line) -> nil
      true -> parse_module_with_quantity(line)
    end
  end

  defp strip_offline(line) do
    String.replace(line, @offline_pattern, "")
  end

  defp parse_module_with_quantity(line) do
    case Regex.run(@quantity_pattern, line) do
      [_, name, qty] -> %{name: String.trim(name), quantity: String.to_integer(qty)}
      _ -> %{name: line, quantity: 1}
    end
  end

  defp encode_section(modules) when is_list(modules) do
    modules
    |> Enum.map(fn
      %{name: name, quantity: 1} -> name
      %{name: name, quantity: qty} -> "#{name} x#{qty}"
    end)
    |> Enum.join("\n")
  end
  defp encode_section(_), do: ""
end
```

#### 4.5 DNA Format Parser

```elixir
defmodule AbyssalWatch.Fittings.Parsers.DNA do
  @moduledoc """
  Parser for EVE DNA fitting format.

  DNA is a compact single-line format using type IDs, enabling:
  - In-game chat links via <url=fitting:DNA>Name</url>
  - Compact URL sharing
  - Efficient database storage

  Grammar:
    DNA := SHIP_ID ":" HIGHS ":" MEDS ":" LOWS ":" RIGS ":" CHARGES
    HIGHS/MEDS/LOWS/RIGS := (TYPE_ID ";" QUANTITY)*
    CHARGES := TYPE_ID (";" TYPE_ID)*

  Example: 17703:2048;2:3170;2:2553;2:31788;2:31366:
  """

  @doc """
  Parse a DNA string into a fitting structure.
  """
  def parse(dna_string) do
    parts = String.split(dna_string, ":")

    with {:ok, ship_type_id} <- parse_ship_id(Enum.at(parts, 0)),
         {:ok, high_slots} <- parse_slot_section(Enum.at(parts, 1, "")),
         {:ok, med_slots} <- parse_slot_section(Enum.at(parts, 2, "")),
         {:ok, low_slots} <- parse_slot_section(Enum.at(parts, 3, "")),
         {:ok, rig_slots} <- parse_slot_section(Enum.at(parts, 4, "")),
         {:ok, charges} <- parse_charges(Enum.at(parts, 5, "")) do
      {:ok, %{
        ship_type_id: ship_type_id,
        high_slots: high_slots,
        med_slots: med_slots,
        low_slots: low_slots,
        rig_slots: rig_slots,
        charges: charges
      }}
    end
  end

  @doc """
  Encode a fitting structure into a DNA string.
  """
  def encode(fitting) do
    [
      fitting.ship_type_id,
      encode_slot_section(fitting.high_slots),
      encode_slot_section(fitting.med_slots),
      encode_slot_section(fitting.low_slots),
      encode_slot_section(fitting.rig_slots),
      encode_charges(fitting.charges)
    ]
    |> Enum.join(":")
  end

  @doc """
  Generate an in-game chat link for the fitting.
  Players can paste this in EVE chat and others can click to open the fit.
  """
  def to_ingame_link(fitting, name) do
    dna = encode(fitting)
    "<url=fitting:#{dna}>#{name}</url>"
  end

  @doc """
  Generate a shareable URL for AbyssalWatch.
  """
  def to_share_url(fitting, base_url \\ "https://abyssalwatch.com") do
    dna = encode(fitting)
    "#{base_url}/fit/#{URI.encode(dna)}"
  end

  defp parse_ship_id(nil), do: {:error, "Missing ship type ID"}
  defp parse_ship_id(""), do: {:error, "Missing ship type ID"}
  defp parse_ship_id(id_str) do
    case Integer.parse(id_str) do
      {id, ""} -> {:ok, id}
      _ -> {:error, "Invalid ship type ID: #{id_str}"}
    end
  end

  defp parse_slot_section(nil), do: {:ok, []}
  defp parse_slot_section(""), do: {:ok, []}
  defp parse_slot_section(section) do
    modules =
      section
      |> String.split(";")
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [type_id, quantity] ->
          %{type_id: String.to_integer(type_id), quantity: String.to_integer(quantity)}
        [type_id] ->
          %{type_id: String.to_integer(type_id), quantity: 1}
      end)

    {:ok, modules}
  end

  defp parse_charges(nil), do: {:ok, []}
  defp parse_charges(""), do: {:ok, []}
  defp parse_charges(section) do
    charges =
      section
      |> String.split(";")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)

    {:ok, charges}
  end

  defp encode_slot_section([]), do: ""
  defp encode_slot_section(modules) do
    modules
    |> Enum.flat_map(fn %{type_id: id, quantity: qty} -> [id, qty] end)
    |> Enum.join(";")
  end

  defp encode_charges([]), do: ""
  defp encode_charges(charges), do: Enum.join(charges, ";")
end
```

#### 4.6 XML Format Parser

```elixir
defmodule AbyssalWatch.Fittings.Parsers.XML do
  @moduledoc """
  Parser for EVE XML fitting format.

  Used for file import/export, supports multiple fittings per file.

  Example:
  <fittings>
    <fitting name="My Fit">
      <description value="A description"/>
      <shipType value="Vexor Navy Issue"/>
      <hardware slot="low slot 0" type="Damage Control II"/>
      <hardware slot="med slot 0" type="10MN Afterburner II"/>
      <hardware slot="hi slot 0" type="Medium Energy Neutralizer II"/>
      <hardware slot="rig slot 0" type="Medium Auxiliary Nano Pump I"/>
      <hardware qty="5" slot="drone bay" type="Hobgoblin II"/>
    </fitting>
  </fittings>
  """

  @doc """
  Parse XML fitting file content. Returns list of fittings.
  """
  def parse(xml_content) do
    with {:ok, doc} <- parse_xml(xml_content) do
      fittings = extract_fittings(doc)
      {:ok, fittings}
    end
  end

  @doc """
  Parse a single fitting element.
  """
  def parse_fitting(fitting_xml) do
    with {:ok, doc} <- parse_xml(fitting_xml) do
      [fitting] = extract_fittings(doc)
      {:ok, fitting}
    end
  end

  @doc """
  Encode fittings to XML format.
  """
  def encode(fittings) when is_list(fittings) do
    fitting_elements = Enum.map(fittings, &encode_fitting/1)

    """
    <?xml version="1.0"?>
    <fittings>
    #{Enum.join(fitting_elements, "\n")}
    </fittings>
    """
  end

  def encode(fitting), do: encode([fitting])

  defp parse_xml(content) do
    # Using Erlang's xmerl for XML parsing
    try do
      {doc, _} = :xmerl_scan.string(String.to_charlist(content))
      {:ok, doc}
    rescue
      _ -> {:error, "Invalid XML format"}
    end
  end

  defp extract_fittings(doc) do
    # Extract all <fitting> elements and parse each
    :xmerl_xpath.string('//fitting', doc)
    |> Enum.map(&parse_fitting_element/1)
  end

  defp parse_fitting_element(fitting_elem) do
    name = get_attribute(fitting_elem, 'name')
    ship_type = get_child_value(fitting_elem, 'shipType')
    description = get_child_value(fitting_elem, 'description')
    hardware = get_hardware(fitting_elem)

    %{
      name: name,
      ship_type: ship_type,
      description: description,
      low_slots: filter_by_slot(hardware, "low slot"),
      med_slots: filter_by_slot(hardware, "med slot"),
      high_slots: filter_by_slot(hardware, "hi slot"),
      rig_slots: filter_by_slot(hardware, "rig slot"),
      drones: filter_by_slot(hardware, "drone bay"),
      cargo: filter_by_slot(hardware, "cargo")
    }
  end

  defp get_hardware(fitting_elem) do
    :xmerl_xpath.string('./hardware', fitting_elem)
    |> Enum.map(fn hw ->
      %{
        slot: get_attribute(hw, 'slot'),
        type: get_attribute(hw, 'type'),
        quantity: get_attribute(hw, 'qty') |> parse_qty()
      }
    end)
  end

  defp filter_by_slot(hardware, slot_prefix) do
    hardware
    |> Enum.filter(&String.starts_with?(&1.slot, slot_prefix))
    |> Enum.map(&%{name: &1.type, quantity: &1.quantity})
  end

  defp parse_qty(nil), do: 1
  defp parse_qty(""), do: 1
  defp parse_qty(qty), do: String.to_integer(qty)

  defp encode_fitting(fitting) do
    hardware_lines =
      [
        encode_slots(fitting.low_slots, "low slot"),
        encode_slots(fitting.med_slots, "med slot"),
        encode_slots(fitting.high_slots, "hi slot"),
        encode_slots(fitting.rig_slots, "rig slot"),
        encode_slots(fitting.drones, "drone bay"),
        encode_slots(fitting.cargo, "cargo")
      ]
      |> List.flatten()
      |> Enum.join("\n    ")

    """
      <fitting name="#{escape_xml(fitting.name)}">
        <description value="#{escape_xml(fitting.description || "")}"/>
        <shipType value="#{escape_xml(fitting.ship_type)}"/>
        #{hardware_lines}
      </fitting>
    """
  end

  defp encode_slots(modules, slot_prefix) do
    modules
    |> Enum.with_index()
    |> Enum.map(fn {mod, idx} ->
      slot = if slot_prefix in ["drone bay", "cargo"], do: slot_prefix, else: "#{slot_prefix} #{idx}"
      qty_attr = if mod.quantity > 1, do: ~s( qty="#{mod.quantity}"), else: ""
      ~s(<hardware slot="#{slot}" type="#{escape_xml(mod.name)}"#{qty_attr}/>)
    end)
  end

  defp escape_xml(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
```

#### 4.7 Updated Fitting Resource

```elixir
defmodule AbyssalWatch.Fittings.Fitting do
  use Ash.Resource,
    domain: AbyssalWatch.Fittings,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "fittings"
    repo AbyssalWatch.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false
    attribute :ship_type_id, :integer, allow_nil?: false
    attribute :ship_type_name, :string
    attribute :modules, :map, default: %{}       # Full module details
    attribute :dna, :string                       # Compact DNA representation
    attribute :constraints, :map, default: %{}
    attribute :source, :atom, default: :manual   # :manual | :eft | :dna | :xml | :esi
    attribute :source_format, :string            # Original import format

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, AbyssalWatch.Accounts.User, allow_nil?: false
  end

  calculations do
    calculate :ingame_link, :string do
      calculation fn records, _ ->
        Enum.map(records, fn record ->
          if record.dna do
            "<url=fitting:#{record.dna}>#{record.name}</url>"
          else
            nil
          end
        end)
      end
    end

    calculate :share_url, :string do
      calculation fn records, _ ->
        base_url = Application.get_env(:abyssalwatch, :base_url, "https://abyssalwatch.com")
        Enum.map(records, fn record ->
          if record.dna do
            "#{base_url}/fit/#{URI.encode(record.dna)}"
          else
            nil
          end
        end)
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :ship_type_id, :ship_type_name, :modules, :dna, :constraints, :source]
      change relate_actor(:user)
    end

    create :from_eft do
      accept [:eft_text]
      change fn changeset, _ ->
        eft_text = Ash.Changeset.get_argument(changeset, :eft_text)
        case AbyssalWatch.Fittings.Parsers.EFT.parse(eft_text) do
          {:ok, parsed} ->
            changeset
            |> Ash.Changeset.change_attribute(:name, parsed.name)
            |> Ash.Changeset.change_attribute(:ship_type_name, parsed.ship_type)
            |> Ash.Changeset.change_attribute(:modules, parsed)
            |> Ash.Changeset.change_attribute(:source, :eft)
          {:error, reason} ->
            Ash.Changeset.add_error(changeset, field: :eft_text, message: reason)
        end
      end
    end

    create :from_dna do
      accept [:dna_string, :name]
      change fn changeset, _ ->
        dna = Ash.Changeset.get_argument(changeset, :dna_string)
        case AbyssalWatch.Fittings.Parsers.DNA.parse(dna) do
          {:ok, parsed} ->
            changeset
            |> Ash.Changeset.change_attribute(:ship_type_id, parsed.ship_type_id)
            |> Ash.Changeset.change_attribute(:modules, parsed)
            |> Ash.Changeset.change_attribute(:dna, dna)
            |> Ash.Changeset.change_attribute(:source, :dna)
          {:error, reason} ->
            Ash.Changeset.add_error(changeset, field: :dna_string, message: reason)
        end
      end
    end

    update :update do
      primary? true
      accept [:name, :modules, :dna, :constraints]
    end
  end
end
```

### Deliverables
- EVE SSO authentication flow
- Character fitting import from ESI
- Fitting-to-optimization conversion
- Enhanced EFT parser with full format support
- DNA format parser/encoder with in-game link generation
- XML format parser for file import/export
- Shareable fitting URLs
- Multi-format export (EFT, DNA, XML, JSON)

---

## 8. API Design

### REST Endpoints (if needed for external integrations)

```
Authentication:
POST   /api/auth/login
POST   /api/auth/logout
GET    /api/auth/me

Modules:
GET    /api/modules/types
GET    /api/modules/search?type_id=X&max_price=Y
GET    /api/modules/:id
POST   /api/modules/score

Watchlists:
GET    /api/watchlists
POST   /api/watchlists
GET    /api/watchlists/:id
PUT    /api/watchlists/:id
DELETE /api/watchlists/:id

Notifications:
GET    /api/notifications
POST   /api/notifications/:id/read
POST   /api/notifications/read-all

Optimization:
POST   /api/optimize
GET    /api/fittings
POST   /api/fittings/import
POST   /api/fittings/export

ESI:
GET    /api/esi/authorize
GET    /api/esi/callback
GET    /api/esi/fittings
```

### LiveView Routes

```elixir
scope "/", AbyssalWatchWeb do
  pipe_through [:browser, :require_authenticated_user]

  live "/", DashboardLive
  live "/search", SearchLive
  live "/watchlists", WatchlistLive
  live "/watchlists/new", WatchlistLive.Form
  live "/watchlists/:id/edit", WatchlistLive.Form
  live "/optimize", OptimizationLive
  live "/notifications", NotificationLive
end

scope "/", AbyssalWatchWeb do
  pipe_through :browser

  live "/login", AuthLive.Login
  live "/register", AuthLive.Register
  delete "/logout", AuthController, :logout
end
```

---

## 9. Testing Strategy

### Unit Tests

```elixir
# test/abyssalwatch/market/scoring/topsis_test.exs
defmodule AbyssalWatch.Market.Scoring.TopsisTest do
  use ExUnit.Case, async: true

  alias AbyssalWatch.Market.Scoring.{Topsis, Criteria}

  describe "score/2" do
    test "ranks modules by weighted criteria" do
      modules = [
        %{id: "1", price: 100, attributes: %{"damage" => 50}},
        %{id: "2", price: 200, attributes: %{"damage" => 100}},
        %{id: "3", price: 150, attributes: %{"damage" => 80}}
      ]

      criteria = %Criteria{
        price_weight: 0.3,
        performance_weight: 0.7
      }

      result = Topsis.score(modules, criteria)

      # Higher damage weight should favor module 2
      assert hd(result).module.id == "2"
    end

    test "handles empty module list" do
      assert Topsis.score([], Criteria.default()) == []
    end
  end
end
```

### Integration Tests

```elixir
# test/abyssalwatch/watchlists/monitor_test.exs
defmodule AbyssalWatch.Watchlists.MonitorTest do
  use AbyssalWatch.DataCase

  alias AbyssalWatch.Watchlists.Monitor

  describe "process_watchlist/1" do
    test "finds matching modules and sends notifications" do
      user = insert(:user)
      watchlist = insert(:watchlist, user: user, notifications_enabled: true)

      # Mock Mutamarket response
      expect(MockMutamarket, :search_modules, fn _type_id, _opts ->
        {:ok, [build(:module, price: 50_000_000)]}
      end)

      Monitor.process_watchlist(watchlist)

      assert_received {:new_matches, %{watchlist_id: ^watchlist.id}}
    end
  end
end
```

### LiveView Tests

```elixir
# test/abyssalwatch_web/live/search_live_test.exs
defmodule AbyssalWatchWeb.SearchLiveTest do
  use AbyssalWatchWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "search" do
    test "displays search results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")

      html =
        view
        |> element("form#search-form")
        |> render_submit(%{type_id: "52227"})

      assert html =~ "Loading..."

      # Wait for async search to complete
      assert render(view) =~ "results found"
    end
  end
end
```

---

## 10. Deployment Considerations

### Environment Variables

```bash
# Database
DATABASE_URL=postgres://user:pass@host:5432/abyssalwatch

# Phoenix
SECRET_KEY_BASE=...
PHX_HOST=abyssalwatch.example.com
PORT=4000

# EVE ESI
EVE_CLIENT_ID=...
EVE_CLIENT_SECRET=...
EVE_CALLBACK_URL=https://abyssalwatch.example.com/api/esi/callback

# Mutamarket
MUTAMARKET_BASE_URL=https://mutamarket.com/api
MUTAMARKET_CACHE_TTL=86400

# Discord Integration (Optional - for system-wide notifications)
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
DISCORD_DEFAULT_MENTION_ROLE_ID=123456789012345678

# Notification Settings
MAX_DISCORD_NOTIFICATIONS_PER_HOUR=30
DISCORD_RATE_LIMIT_WINDOW_SECONDS=60
```

### Docker Deployment

```dockerfile
FROM elixir:1.16-alpine AS build

RUN apk add --no-cache build-base git

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY . .
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix assets.deploy
RUN MIX_ENV=prod mix release

FROM alpine:3.18 AS app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/abyssalwatch ./

ENV HOME=/app
CMD ["bin/abyssalwatch", "start"]
```

### Health Checks

```elixir
# lib/abyssalwatch_web/controllers/health_controller.ex
defmodule AbyssalWatchWeb.HealthController do
  use AbyssalWatchWeb, :controller

  def index(conn, _params) do
    checks = %{
      database: check_database(),
      mutamarket: check_mutamarket(),
      monitor: check_monitor()
    }

    status = if Enum.all?(Map.values(checks), & &1 == :ok), do: 200, else: 503

    json(conn, %{status: status_text(status), checks: checks})
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1") do
      {:ok, _} -> :ok
      _ -> :error
    end
  end
end
```

---

## Timeline Summary

| Phase | Focus | Key Deliverables |
|-------|-------|------------------|
| **Phase 1** | Foundation | Auth, Module Search, TOPSIS Scoring, Mutamarket Integration |
| **Phase 2** | Monitoring | Watchlists, Background Monitor, Real-time Notifications, **Discord Webhooks** |
| **Phase 3** | Optimization | Heuristic Solver, Constraint Solver, Optimization Wizard |
| **Phase 4** | ESI & Formats | EVE SSO, ESI Integration, DNA/EFT/XML Parsers, In-Game Links |

---

## Appendix: Module Types

| ID | Name | Slot |
|----|------|------|
| 52227 | Warp Disruptor | Med |
| 52230 | Stasis Webifier | Med |
| 52224 | Warp Scrambler | Med |
| 52222 | Damage Control | Low |
| 52236 | Afterburner | Med |
| 52239 | Microwarpdrive | Med |
| 52242 | Shield Extender | Med |
| 52245 | Armor Plates | Low |
| 52248 | Shield Booster | Med |
| 52251 | Armor Repairer | Low |
| 52254 | Ancillary Armor Repairer | Low |
| 52257 | Energized Armor Membrane | Low |

---

*This document serves as the implementation roadmap for AbyssalWatch. Each phase builds upon the previous, with clear deliverables and technical specifications.*
