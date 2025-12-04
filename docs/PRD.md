# Product Requirements Document: AbyssalWatch

**Product Name:** AbyssalWatch
**Version:** 3.0
**Last Updated:** December 2025
**Status:** Reimplementation in Progress

---

## 1. Executive Summary

AbyssalWatch is a standalone reimplementation of the Abyssal Module functionality, originally part of EVE Corp Tools. Built with Elixir, Phoenix, and the Ash Framework, it provides EVE Online players with comprehensive tools to search, analyze, score, and optimize abyssal (mutaplasmid-modified) modules for their ship fittings.

### 1.1 Vision

Become the premier platform for EVE Online abyssal module analysis, enabling players to make data-driven decisions when purchasing and optimizing mutated modules for their ship fittings.

### 1.2 Mission

Provide EVE Online players with advanced tools to search, analyze, score, and optimize abyssal modules through intelligent market analysis, constraint-based optimization, and real-time monitoring capabilities.

### 1.3 Key Value Propositions

- **Market Discovery**: Find abyssal modules matching specific attribute requirements across the market
- **Intelligent Scoring**: Multi-criteria scoring using TOPSIS algorithm for objective module comparison
- **Fit Optimization**: Automated optimization of ship fittings with constraint satisfaction
- **Proactive Alerts**: Watchlist-based notifications when desirable modules appear on the market
- **ESI Integration**: Seamless import/export of ship fittings from EVE Online
- **Real-time Updates**: Phoenix LiveView for instant UI updates and notifications

### 1.4 Why Reimplementation?

The original Go implementation was part of a larger monolithic application. This reimplementation:

- **Standalone Service**: Dedicated application focused solely on abyssal module functionality
- **Modern Stack**: Elixir/Phoenix provides superior concurrency, fault tolerance, and real-time capabilities
- **Declarative Data Layer**: Ash Framework enables cleaner domain modeling and automatic API generation
- **LiveView**: Server-rendered real-time UI eliminates frontend/backend synchronization complexity
- **Simplified Deployment**: Single application with fewer moving parts

---

## 2. Problem Statement

EVE Online abyssal modules (mutated modules from Abyssal Deadspace sites) present unique challenges:

1. **Complex Evaluation**: Each module has randomized attributes making manual comparison extremely difficult
2. **Market Fragmentation**: Abyssal modules are unique items requiring specialized market platforms
3. **Fit Optimization**: Finding optimal combinations that respect ship constraints is computationally complex
4. **Price Discovery**: Determining fair value for unique attributes is challenging without analytical tools
5. **Market Monitoring**: Tracking availability of specific attribute combinations requires continuous monitoring

---

## 3. Target Users

### 3.1 User Profiles

| User Type | Description | Primary Use Cases |
|-----------|-------------|-------------------|
| **PvP Pilots** (Primary) | Players focused on player combat | Optimize combat fits, find best-in-slot modules |
| **Fleet Commanders** | Leaders organizing group activities | Standardize fleet doctrine fits with optimal modules |
| **Market Traders** (Secondary) | Players focused on trading | Track undervalued modules, identify market opportunities |
| **Theorycrafters** (Tertiary) | Players who optimize ship builds | Compare module variations, test optimization scenarios |

### 3.2 User Needs

- Quickly find abyssal modules that meet specific attribute thresholds
- Compare modules objectively using weighted scoring
- Automate the tedious process of fitting optimization
- Receive alerts when sought-after modules become available
- Import existing fits and optimize them with abyssal modules

---

## 4. Business Objectives

### 4.1 Primary Goals

- **Decision Support**: Provide data-driven insights for abyssal module purchasing decisions
- **Optimization**: Enable optimal ship fitting within resource constraints
- **Market Efficiency**: Improve price discovery and market transparency for abyssal modules
- **Time Savings**: Reduce manual analysis time from hours to minutes

### 4.2 Success Metrics

| Metric | Target |
|--------|--------|
| Search result relevance | >90% user satisfaction with module recommendations |
| Optimization accuracy | Solutions within 5% of theoretical optimum |
| Market coverage | >95% of available modules indexed and analyzed |
| User engagement | >60% of users return within 7 days |
| Cache hit rate | >80% for market data |
| API error rate | <1% for external service calls |

---

## 5. Feature Specifications

### 5.1 Module Search & Market Analysis

**Description**: Search and filter abyssal modules from external market sources based on type, attributes, and price.

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| MS-01 | Search modules by type (12+ supported types) | 1 | 🔲 Planned |
| MS-02 | Filter by price range (min/max ISK) | 1 | 🔲 Planned |
| MS-03 | Filter by attribute values with min/max thresholds | 1 | 🔲 Planned |
| MS-04 | Display module details including all mutated attributes | 1 | 🔲 Planned |
| MS-05 | Sort results by price, score, or specific attributes | 1 | 🔲 Planned |
| MS-06 | Save searches for future reuse | 1 | 🔲 Planned |
| MS-07 | Track search history per user | 1 | 🔲 Planned |
| MS-08 | Display market trends and top modules | 1 | 🔲 Planned |

**Supported Module Types**:
1. Warp Disruptor
2. Stasis Webifier
3. Warp Scrambler
4. Damage Control
5. Afterburner
6. Microwarpdrive (MWD)
7. Shield Extender
8. Armor Plates
9. Shield Booster
10. Armor Repairer
11. Ancillary Armor Repairer
12. Energized Armor Membrane (Plating)

**Data Source**: Mutamarket.com API with 24-hour caching

**Implementation Notes**:
- Ash Resource: `AbyssalWatch.Market.Module`
- LiveView: `AbyssalWatchWeb.SearchLive`
- Cache: ETS with 24-hour TTL
- Rate Limiting: Token bucket (5/sec, 10 burst)

---

### 5.2 Module Scoring System

**Description**: Objective scoring of abyssal modules using the TOPSIS (Technique for Order of Preference by Similarity to Ideal Solution) multi-criteria decision-making algorithm.

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| SC-01 | Calculate weighted scores based on user-defined criteria | 1 | 🔲 Planned |
| SC-02 | Support four scoring dimensions: price, performance, efficiency, volume | 1 | 🔲 Planned |
| SC-03 | Provide score breakdown showing component contributions | 1 | 🔲 Planned |
| SC-04 | Validate weights sum to 1.0 | 1 | 🔲 Planned |
| SC-05 | Support preset scoring profiles (Default, Conservative, Aggressive) | 1 | 🔲 Planned |
| SC-06 | Account for attribute directionality (higher/lower is better) | 1 | 🔲 Planned |
| SC-07 | Real-time re-scoring when criteria change | 1 | 🔲 Planned |

**Scoring Criteria**:
- **Price**: Cost efficiency weight (cost-minimize mode)
- **Performance**: Combat effectiveness (DPS, tank, speed attributes)
- **Efficiency**: Value per ISK spent
- **Volume**: Cargo/logistics considerations

**Scoring Profile Presets**:

| Profile | Price | Performance | Efficiency | Volume |
|---------|-------|-------------|------------|--------|
| Default | 0.25 | 0.35 | 0.30 | 0.10 |
| Conservative | 0.40 | 0.20 | 0.35 | 0.05 |
| Aggressive | 0.10 | 0.50 | 0.25 | 0.15 |

**Implementation Notes**:
- Module: `AbyssalWatch.Market.Scoring.Topsis`
- Pure Elixir implementation with vector normalization
- Ideal/anti-ideal solution calculation
- Euclidean distance for relative closeness

---

### 5.3 Watchlist Management

**Description**: Create and manage watchlists to track specific module configurations and receive notifications when matching modules appear.

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| WL-01 | Create watchlists with module type and attribute targets | 2 | 🔲 Planned |
| WL-02 | Set "important" attributes with minimum required values | 2 | 🔲 Planned |
| WL-03 | Set "unimportant" attributes with maximum thresholds | 2 | 🔲 Planned |
| WL-04 | Configure price threshold for watchlist | 2 | 🔲 Planned |
| WL-05 | Enable/disable notifications per watchlist | 2 | 🔲 Planned |
| WL-06 | View all watchlists with status indicators | 2 | 🔲 Planned |
| WL-07 | Edit existing watchlist criteria | 2 | 🔲 Planned |
| WL-08 | Delete watchlists | 2 | 🔲 Planned |
| WL-09 | Filter watchlists by active/inactive status | 2 | 🔲 Planned |

**Data Model** (Ash Resource):
```elixir
AbyssalWatch.Watchlists.Watchlist:
  - id: UUID (primary key)
  - user_id: UUID (belongs_to User)
  - name: String
  - module_type_id: Integer
  - module_type_name: String
  - important_attributes: Map (JSONB)
  - unimportant_attributes: Map (JSONB)
  - price_threshold: Decimal
  - notifications_enabled: Boolean (default: true)
  - created_at, updated_at: Timestamps
```

**Implementation Notes**:
- Ash Resource: `AbyssalWatch.Watchlists.Watchlist`
- LiveView: `AbyssalWatchWeb.WatchlistLive`
- Real-time updates via Phoenix.PubSub

---

### 5.4 Notification System

**Description**: Real-time and historical notifications when modules matching watchlist criteria become available.

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| NT-01 | Generate notifications when modules match watchlist criteria | 2 | 🔲 Planned |
| NT-02 | Prevent duplicate notifications for same module within 24 hours | 2 | 🔲 Planned |
| NT-03 | Deliver real-time notifications via LiveView | 2 | 🔲 Planned |
| NT-04 | Store notification history with timestamps | 2 | 🔲 Planned |
| NT-05 | Mark notifications as read | 2 | 🔲 Planned |
| NT-06 | Mark all notifications as read | 2 | 🔲 Planned |
| NT-07 | Delete individual notifications | 2 | 🔲 Planned |
| NT-08 | Filter notification history by watchlist or date | 2 | 🔲 Planned |

**Data Model** (Ash Resource):
```elixir
AbyssalWatch.Watchlists.Notification:
  - id: UUID (primary key)
  - user_id: UUID (belongs_to User)
  - watchlist_id: UUID (belongs_to Watchlist)
  - module_id: String (external reference)
  - read: Boolean (default: false)
  - sent_at: DateTime (immutable)

  Indexes:
    - (watchlist_id, module_id) for deduplication
    - (user_id, sent_at) for history queries
```

**Matching Algorithm**:
1. Evaluate module attributes against `important_attributes` (must meet minimum)
2. Check `unimportant_attributes` (must not exceed maximum)
3. Apply `price_threshold` filter
4. Check 24-hour deduplication window
5. Send notification if all criteria satisfied

**Implementation Notes**:
- Background Monitor: `AbyssalWatch.Watchlists.Monitor` (GenServer)
- Matcher: `AbyssalWatch.Watchlists.Matcher`
- Notifier: `AbyssalWatch.Watchlists.Notifier` (Phoenix.PubSub)
- Check interval: 10 minutes
- Concurrent processing: 5 watchlists at a time

---

### 5.5 Ship Fit Optimization

**Description**: Automated optimization of ship fittings using abyssal modules with constraint satisfaction.

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| OP-01 | Import fits from clipboard (EFT format) | 3 | 🔲 Planned |
| OP-02 | Import fits from file upload | 3 | 🔲 Planned |
| OP-03 | Import fits from ESI (in-game fittings) | 4 | 🔲 Planned |
| OP-04 | Configure CPU capacity constraint | 3 | 🔲 Planned |
| OP-05 | Configure Power Grid capacity constraint | 3 | 🔲 Planned |
| OP-06 | Configure Calibration capacity constraint | 3 | 🔲 Planned |
| OP-07 | Configure slot requirements (High/Med/Low/Rig) | 3 | 🔲 Planned |
| OP-08 | Set maximum budget constraint | 3 | 🔲 Planned |
| OP-09 | Configure scoring weight objectives | 3 | 🔲 Planned |
| OP-10 | Choose solver mode (Heuristic or Constraint) | 3 | 🔲 Planned |
| OP-11 | Display multiple ranked solutions | 3 | 🔲 Planned |
| OP-12 | Show resource usage breakdown per solution | 3 | 🔲 Planned |
| OP-13 | Export optimized fit to various formats | 3 | 🔲 Planned |
| OP-14 | Display optimization progress in real-time | 3 | 🔲 Planned |

**Optimization Workflow (5-Step Wizard)**:
1. **Import Fit**: Load existing fit via clipboard, file, or ESI
2. **Configure Constraints**: Set CPU, power grid, calibration limits
3. **Set Objectives**: Define scoring weights for optimization
4. **Run Optimization**: Execute solver algorithm
5. **Review & Export**: Analyze solutions and export results

**Solver Modes**:
- **Heuristic**: Fast greedy algorithm for rapid results (<2s typical)
- **Constraint**: Pure Elixir branch-and-bound solver for thorough exploration (<30s complex fits)

**Constraint Model**:
```elixir
AbyssalWatch.Optimization.Types.Constraints:
  - cpu_capacity: Float (available CPU in tf)
  - power_capacity: Float (available power grid in MW)
  - calibration_capacity: Float (rig calibration points)
  - max_price: Decimal (optional budget limit in ISK)
  - available_slots: %{high: Int, med: Int, low: Int, rig: Int}
```

**Solution Output**:
```elixir
AbyssalWatch.Optimization.Types.Solution:
  - id: String (unique identifier)
  - rank: Integer (1, 2, 3...)
  - modules: [ModuleCandidate]
  - total_score: Float
  - total_price: Decimal
  - efficiency: Float (score per ISK)
  - resource_usage: %{cpu: Float, power: Float, calibration: Float}
  - score_breakdown: Map
```

**Implementation Notes**:
- Engine: `AbyssalWatch.Optimization.Engine`
- Heuristic Solver: `AbyssalWatch.Optimization.Solvers.Heuristic`
- Constraint Solver: `AbyssalWatch.Optimization.Solvers.Constraint`
- LiveView: `AbyssalWatchWeb.OptimizationLive`
- Multi-step wizard with LiveView components

---

### 5.6 ESI Integration

**Description**: Integration with EVE Online's ESI (EVE Swagger Interface) for ship fitting import/export.

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| ESI-01 | Authenticate via EVE SSO OAuth2 | 4 | 🔲 Planned |
| ESI-02 | List character's saved fittings | 4 | 🔲 Planned |
| ESI-03 | Import fitting into optimization workflow | 4 | 🔲 Planned |
| ESI-04 | Convert ESI fitting format to optimization parameters | 4 | 🔲 Planned |
| ESI-05 | Export optimized fit to EFT format | 3 | 🔲 Planned |
| ESI-06 | Export optimized fit to JSON format | 3 | 🔲 Planned |
| ESI-07 | List character's ships | 4 | 🔲 Planned |

**Implementation Notes**:
- OAuth: `AbyssalWatch.Fittings.ESI.OAuth`
- Client: `AbyssalWatch.Fittings.ESI.Client`
- EFT Parser: `AbyssalWatch.Fittings.Parsers.EFT`

---

### 5.7 Advanced Fitting Formats

**Description**: Support for official EVE fitting formats (EFT, DNA, XML) as documented in the EVE Developer documentation, enabling in-game integration and cross-tool compatibility.

**Reference**: https://developers.eveonline.com/docs/guides/fitting/

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| FF-01 | Enhanced EFT parser with `/offline` notation handling | 4 | 🔲 Planned |
| FF-02 | Enhanced EFT parser with `x##` quantity suffixes (drones/cargo) | 4 | 🔲 Planned |
| FF-03 | Enhanced EFT parser with empty slot markers `[Empty X slot]` | 4 | 🔲 Planned |
| FF-04 | Parse DNA format (`SHIP_ID:HIGHS:MEDS:LOWS:RIGS:CHARGES`) | 4 | 🔲 Planned |
| FF-05 | Encode fittings to DNA format | 4 | 🔲 Planned |
| FF-06 | Generate in-game chat links (`<url=fitting:DNA>Name</url>`) | 4 | 🔲 Planned |
| FF-07 | Shareable fitting URLs using DNA format | 4 | 🔲 Planned |
| FF-08 | XML fitting format import (single and multi-fit files) | 4 | 🔲 Planned |
| FF-09 | XML fitting format export | 4 | 🔲 Planned |
| FF-10 | Support localized type names in EFT format | 4 | 🔲 Planned |

**Fitting Format Details**:

| Format | Structure | Use Case |
|--------|-----------|----------|
| **EFT** | `[Ship, Name]` header + modules by slot section | Clipboard copy/paste, in-game simulation |
| **DNA** | `SHIP_ID:TYPE;QTY:TYPE;QTY:...` | Compact URLs, in-game chat links, efficient storage |
| **XML** | `<fitting><hardware slot="X" type="Y"/></fitting>` | File import/export, multi-fit operations |

**DNA Format Grammar**:
```
DNA := SHIP_ID ":" HIGHS ":" MEDS ":" LOWS ":" RIGS ":" CHARGES
HIGHS/MEDS/LOWS/RIGS := (TYPE_ID ";" QUANTITY)*
CHARGES := TYPE_ID (";" TYPE_ID)*
```

**In-Game Link Generation**:
- Users can copy a link from AbyssalWatch
- Paste in EVE chat: `<url=fitting:17703:2048;2:3170;2>My Fit</url>`
- Other players click → fitting opens in-game

**Implementation Notes**:
- EFT Parser: `AbyssalWatch.Fittings.Parsers.EFT` (enhanced)
- DNA Parser: `AbyssalWatch.Fittings.Parsers.DNA` (new)
- XML Parser: `AbyssalWatch.Fittings.Parsers.XML` (new)
- Fitting resource stores DNA string for compact representation

---

### 5.8 Dashboard & Analytics

**Description**: Overview dashboard displaying key metrics, trends, and recent activity.

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| DA-01 | Display active listings count | 1 | 🔲 Planned |
| DA-02 | Display average module value | 1 | 🔲 Planned |
| DA-03 | Display alert count (unread notifications) | 2 | 🔲 Planned |
| DA-04 | Display active watchlist count | 2 | 🔲 Planned |
| DA-05 | Show trending indicators (direction/percentage) | 2 | 🔲 Planned |
| DA-06 | List top modules by value/score | 1 | 🔲 Planned |
| DA-07 | Display recent search history | 1 | 🔲 Planned |
| DA-08 | Show recent notifications | 2 | 🔲 Planned |

**Implementation Notes**:
- LiveView: `AbyssalWatchWeb.DashboardLive`
- Real-time updates via PubSub subscriptions

---

### 5.9 Real-Time Updates

**Description**: Phoenix LiveView and PubSub for live updates and notifications.

**Functional Requirements**:

| ID | Requirement | Phase | Status |
|----|-------------|-------|--------|
| RT-01 | Automatic LiveView connection on page load | 1 | 🔲 Planned |
| RT-02 | Subscribe to user-specific update channels | 2 | 🔲 Planned |
| RT-03 | Receive notifications in real-time | 2 | 🔲 Planned |
| RT-04 | Handle graceful reconnection on disconnect | 1 | 🔲 Planned |
| RT-05 | Broadcast messages to multiple clients | 2 | 🔲 Planned |

**Implementation Notes**:
- Phoenix LiveView handles WebSocket connections automatically
- Phoenix.PubSub for broadcast messaging
- Automatic reconnection built into LiveView

---

## 6. Planned Features (Future Roadmap)

The following features are considered for future development after core implementation:

### 6.1 High Priority

| ID | Feature | Description | Complexity |
|----|---------|-------------|------------|
| PF-01 | **Push Notifications** | Browser push notifications for watchlist matches | Medium |
| PF-02 | **Discord Integration** | Send notifications to Discord channels/DMs | Medium |
| PF-03 | **Email Notifications** | Email alerts for watchlist matches | Low |

### 6.2 Medium Priority

| ID | Feature | Description | Complexity |
|----|---------|-------------|------------|
| PF-04 | **Historical Pricing** | Track and display price history/trends over time | Medium |
| PF-05 | **Advanced Market Analytics** | Price movement indicators, trend forecasting | High |
| PF-06 | **Fleet Optimization** | Optimize modules across multiple ships | High |
| PF-07 | **Watchlist Sharing** | Share watchlists with corp members or public | Medium |
| PF-08 | **Fitting Sharing** | Share optimized fits via shareable links | Medium |

### 6.3 Low Priority

| ID | Feature | Description | Complexity |
|----|---------|-------------|------------|
| PF-09 | **ML-Based Scoring** | ML scoring using community preferences | Very High |
| PF-10 | **Price Prediction** | Predictive analytics for price movements | Very High |
| PF-11 | **Bulk Watchlist Operations** | Bulk import/export of watchlists | Low |
| PF-12 | **External Tool Integration** | Integration with Pyfa, EFT tools | Medium |
| PF-13 | **Mobile App** | Native mobile application | Very High |

---

## 7. Technical Architecture

### 7.1 Technology Stack

| Component | Technology | Rationale |
|-----------|------------|-----------|
| Language | Elixir 1.16+ | Concurrency, fault tolerance, pattern matching |
| Framework | Phoenix 1.7+ | Mature web framework, excellent LiveView support |
| Data Layer | Ash Framework 3.x | Declarative resources, built-in actions, extensions |
| Database | PostgreSQL 16+ | JSON support, excellent indexing |
| Real-time | Phoenix LiveView | Server-rendered real-time UI |
| Background Jobs | GenServer | Simple, no external dependencies |
| Caching | ETS | In-memory, concurrent reads |
| HTTP Client | Req | Modern, composable HTTP client |

### 7.2 Project Structure

```
lib/abyssalwatch/
├── application.ex              # OTP Application
├── repo.ex                     # Ecto Repo
│
├── accounts/                   # User/Auth domain
│   ├── accounts.ex             # Ash Domain
│   ├── user.ex                 # Ash Resource
│   └── token.ex                # Session tokens
│
├── market/                     # Market data domain
│   ├── market.ex               # Ash Domain
│   ├── resources/
│   │   ├── module.ex           # Abyssal module resource
│   │   ├── module_type.ex      # Module type definitions
│   │   └── module_attribute.ex # Attribute metadata
│   ├── mutamarket/
│   │   ├── client.ex           # HTTP client
│   │   ├── cache.ex            # ETS caching
│   │   └── rate_limiter.ex     # Token bucket
│   └── scoring/
│       ├── topsis.ex           # TOPSIS algorithm
│       ├── criteria.ex         # Scoring criteria
│       └── presets.ex          # Profile presets
│
├── watchlists/                 # Watchlist domain
│   ├── watchlists.ex           # Ash Domain
│   ├── resources/
│   │   ├── watchlist.ex        # Watchlist resource
│   │   └── notification.ex     # Notification resource
│   ├── monitor.ex              # Background GenServer
│   ├── matcher.ex              # Matching logic
│   └── notifier.ex             # PubSub notifications
│
├── optimization/               # Optimization domain
│   ├── optimization.ex         # Ash Domain
│   ├── engine.ex               # Coordinator
│   ├── solvers/
│   │   ├── heuristic.ex        # Greedy solver
│   │   └── constraint.ex       # Branch-and-bound
│   ├── constraints.ex          # Constraint definitions
│   └── types.ex                # ModuleCandidate, Solution
│
└── fittings/                   # Ship fittings domain
    ├── fittings.ex             # Ash Domain
    ├── resources/
    │   └── fitting.ex          # Saved fitting resource
    ├── esi/
    │   ├── client.ex           # ESI API client
    │   └── oauth.ex            # EVE SSO OAuth2
    └── parsers/
        ├── eft.ex              # EFT format parser
        └── esi.ex              # ESI format converter
```

### 7.3 LiveView Structure

```
lib/abyssalwatch_web/
├── router.ex
├── endpoint.ex
├── components/
│   ├── core_components.ex
│   ├── module_card.ex
│   ├── score_breakdown.ex
│   └── filter_panel.ex
└── live/
    ├── dashboard_live.ex
    ├── search_live.ex
    ├── watchlist_live.ex
    ├── optimization_live.ex
    └── notification_live.ex
```

### 7.4 Database Schema

**Tables** (PostgreSQL 16+):

| Table | Purpose | Key Indexes |
|-------|---------|-------------|
| `users` | User accounts | email |
| `modules` | Cached module data | type_id, price, (available, last_seen), score |
| `watchlists` | User watchlists | user_id, module_type_id |
| `notifications` | Notification history | (watchlist_id, module_id), (user_id, sent_at) |
| `fittings` | Saved fittings | user_id |

### 7.5 External Integrations

| Service | Purpose | Rate Limits | Caching |
|---------|---------|-------------|---------|
| Mutamarket.com API | Abyssal module market data | 5 req/sec, 10-burst | 24-hour TTL |
| EVE ESI API | Ship fittings, character data | Per ESI limits | Session-scoped |

### 7.6 Reliability Features

- **Rate Limiting**: Token bucket (5/sec, 10 burst) for Mutamarket
- **Circuit Breaker**: Fault tolerance for external services (via Req)
- **Retry Logic**: Exponential backoff on transient failures
- **Caching**: ETS with configurable TTL
- **Supervision**: OTP supervision tree for fault recovery

---

## 8. Implementation Phases

### Phase 1: Foundation & Module Search
- Project setup with Phoenix/Ash
- Mutamarket API integration with caching
- TOPSIS scoring algorithm
- Module search LiveView (anonymous access)
- Dashboard with basic metrics
- Session-based preferences (no user accounts yet)

### Phase 2: Watchlists & Notifications
- Watchlist CRUD with Ash resources
- Background monitor GenServer
- Matching algorithm
- Real-time notifications via PubSub
- Notification history and management
- *Note: Requires user accounts from Phase 4; can develop with temporary local auth*

### Phase 3: Optimization Engine
- Heuristic (greedy) solver
- Branch-and-bound constraint solver
- Optimization wizard LiveView
- EFT format parser and export
- Solution comparison UI

### Phase 4: ESI Integration & Advanced Fitting Formats
- **EVE SSO OAuth2 as primary authentication** (replaces local accounts)
- User resource linked to EVE character data
- Character fittings import from ESI
- ESI format conversion
- Full fitting workflow integration
- DNA format parser and encoder (compact fitting representation)
- Enhanced EFT parser (offline notation, quantities, empty slots)
- In-game chat link generation (`<url=fitting:...>`)
- XML fitting format import/export
- Shareable fitting URLs

---

## 9. Non-Functional Requirements

### 9.1 Performance

| Metric | Target |
|--------|--------|
| Module search response | < 500ms (cache hit), < 3s (cache miss) |
| Optimization (Heuristic) | < 2s typical |
| Optimization (Constraint) | < 30s complex fits |
| LiveView latency | < 100ms for UI updates |
| Dashboard loading | < 2s |
| Cache hit rate | > 80% |

### 9.2 Accuracy

| Metric | Target |
|--------|--------|
| TOPSIS scoring consistency | Mathematically consistent rankings |
| Constraint validation | > 99.9% accuracy |
| Optimization solutions | Within 5% of theoretical optimum |
| Market data freshness | Within 24 hours of source |

### 9.3 Reliability

| Metric | Target |
|--------|--------|
| System uptime | 99.5% |
| External API fault tolerance | Circuit breaker protection |
| Notification delivery | > 99% reliability |

---

## 10. Risk Assessment

### 10.1 Active Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Mutamarket API dependency | High | Circuit breaker, caching, graceful degradation |
| Optimization edge cases | Medium | Comprehensive test coverage, fallback to heuristic |
| Market data volume | Medium | Database indexing, query optimization, ETS caching |
| Pure Elixir solver performance | Medium | Efficient algorithms, potential Rust NIF for hot paths |

### 10.2 Mitigations

- User experience complexity → Progressive disclosure of advanced features
- Data accuracy delays → 24-hour cache with manual refresh option
- Performance degradation → ETS caching, async operations, LiveView optimizations

---

## 11. Glossary

| Term | Definition |
|------|------------|
| **Abyssal Module** | EVE Online module modified by a Mutaplasmid, resulting in randomized stat changes |
| **Mutaplasmid** | In-game item used to modify modules with random attribute variations |
| **ESI** | EVE Swagger Interface - CCP's official API for EVE Online |
| **EFT Format** | EVE Fitting Tool format - text format for ship fittings used in clipboard operations |
| **DNA Format** | Compact single-line fitting representation using type IDs, enables in-game chat links |
| **XML Format** | File-based fitting format supporting multiple fittings per file |
| **TOPSIS** | Technique for Order of Preference by Similarity to Ideal Solution |
| **Watchlist** | User-defined criteria for monitoring specific module configurations |
| **Mutamarket** | Third-party market website for abyssal modules (mutamarket.com) |
| **Ash Framework** | Elixir framework for declarative domain modeling |
| **LiveView** | Phoenix library for real-time server-rendered UIs |
| **GenServer** | Elixir/OTP behaviour for stateful server processes |

---

## 12. Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Initial | Original PRD with vision and requirements |
| 2.0 | Dec 2025 | Updated to reflect Go implementation |
| 3.0 | Dec 2025 | Reimplementation as AbyssalWatch with Elixir/Phoenix/Ash stack |
