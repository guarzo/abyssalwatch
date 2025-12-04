# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AbyssalWatch is an EVE Online Abyssal Module Analysis Platform built with Elixir, Phoenix 1.8, Ash Framework 3.x, and LiveView. It enables players to search, analyze, score, and optimize mutaplasmid-modified modules for ship fittings.

## Commands

```bash
# Development
mix setup              # Install deps, setup DB, build assets
mix phx.server         # Start Phoenix server (http://localhost:4000)
mix precommit          # Run before committing: compile --warnings-as-errors, unlock unused deps, format, test

# Testing
mix test               # Run all tests
mix test path/to/test.exs        # Run single test file
mix test path/to/test.exs:42     # Run test at specific line
mix test --failed                # Re-run failed tests

# Database
mix ecto.migrate       # Run migrations
mix ecto.reset         # Drop, create, migrate, seed

# Ash-specific
mix ash.codegen        # Generate Ash resource code
```

## Architecture

### Ash Domains (lib/abyssalwatch/)

The app uses Ash Framework with four domains defined in `config/config.exs`:

- **Accounts** - User auth via EVE SSO, tokens, notification settings
- **Market** - Abyssal modules, types, Mutamarket API client, TOPSIS scoring
- **Watchlists** - User watchlists, matching logic, Discord notifications
- **Fittings** - Ship fittings, ESI integration, format parsers (EFT, DNA, XML)

### Web Layer (lib/abyssalwatch_web/)

- **Router** - Public routes at `/`, auth-required ESI routes at `/esi/*`
- **LiveViews** - SearchLive, OptimizationLive, DashboardLive, WatchlistLive, FittingLive, ESIFittingsLive
- **Authentication** - EVE SSO OAuth2 via `Plugs.Auth` and `LiveAuth` on_mount hooks

### Key Background Processes

- `Market.Mutamarket.Cache` - ETS-based API response caching
- `Market.Mutamarket.RateLimiter` - Token bucket rate limiting
- `Watchlists.Monitor` - GenServer for background watchlist checks
- `Watchlists.Discord.Client` - Webhook notifications

## Code Style

### Phoenix 1.8 LiveView

- Templates must begin with `<Layouts.app flash={@flash} ...>` wrapping content
- Use `<.icon name="hero-x-mark">` for icons (never Heroicons modules)
- Use `<.input field={@form[:field]}>` for form inputs
- Use colocated JS hooks (`:type={Phoenix.LiveView.ColocatedHook}`) with `.` prefix names
- For collections, always use LiveView streams with `phx-update="stream"`

### Elixir/Ash

- Use `Req` for HTTP requests (not HTTPoison, Tesla, or :httpc)
- Access struct fields directly (`struct.field`), not via Access syntax
- Use `to_form/2` for all forms, never pass changesets directly to templates
- Predicate functions end with `?` (not `is_` prefix)

### Templates

- Use `{...}` for interpolation in attributes and tag bodies
- Use `<%= %>` only for block constructs (if, cond, case, for)
- HEEx class attrs support conditional lists: `class={["base", @flag && "extra"]}`
- Never use `else if` - use `cond` or `case` instead

### Testing

- Use `start_supervised!/1` for process cleanup
- Use `Process.monitor/1` instead of `Process.sleep/1`
- Test element presence with `has_element?/2`, not raw HTML matching

## External APIs

- **Mutamarket API** - Abyssal module market data (cached, rate-limited)
- **EVE ESI** - Character fittings, OAuth2 via SSO
- **Discord Webhooks** - Watchlist match notifications
