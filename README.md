# AbyssalWatch

EVE Online Abyssal Module Analysis Platform - Search, score, and optimize mutaplasmid-modified modules for your ship fittings.

## Development Setup

This project uses a devcontainer for consistent development environments.

### Prerequisites

- Docker Desktop or Docker Engine with Docker Compose
- VS Code with the "Dev Containers" extension (or compatible IDE)

### Getting Started

1. Open this folder in VS Code
2. When prompted, click "Reopen in Container" (or run `Dev Containers: Reopen in Container` from the command palette)
3. Wait for the container to build and start
4. Install dependencies and set up the database:

```bash
mix setup
```

5. Start the Phoenix server:

```bash
mix phx.server
```

Visit http://localhost:4000 in your browser.

### Environment Variables

For EVE SSO authentication, set the following (optional for local development):

```bash
EVE_CLIENT_ID=your_client_id
EVE_CLIENT_SECRET=your_client_secret
EVE_CALLBACK_URL=http://localhost:4000/auth/eve/callback
```

## Architecture

The application is built with Ash Framework domains:

- **Accounts** (`lib/abyssalwatch/accounts/`) - EVE SSO authentication, user tokens, notification settings
- **Market** (`lib/abyssalwatch/market/`) - Abyssal modules, Mutamarket API integration, TOPSIS scoring
- **Watchlists** (`lib/abyssalwatch/watchlists/`) - Module watchlists, matching, Discord notifications
- **Fittings** (`lib/abyssalwatch/fittings/`) - Ship fittings, ESI integration, format parsers (EFT, DNA, XML)

See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the full implementation plan.

## Features

- **Module Search**: Find abyssal modules by type, attributes, and price
- **TOPSIS Scoring**: Multi-criteria decision analysis for objective module comparison
- **Watchlists**: Monitor specific module configurations with Discord notifications
- **Fit Optimization**: Ship fitting optimization with heuristic and constraint solvers
- **ESI Integration**: Import fittings from EVE Online (requires authentication)
- **Shareable Fittings**: DNA-based URLs for sharing fits

## Tech Stack

- Elixir 1.15+
- Phoenix 1.8 with LiveView
- Ash Framework 3.x
- PostgreSQL

## License

Private - All rights reserved
