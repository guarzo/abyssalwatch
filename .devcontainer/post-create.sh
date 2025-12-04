#!/bin/bash
set -e

echo "==> Running post-create setup..."

# Install Claude Code CLI
echo "==> Installing Claude Code CLI..."
npm install -g @anthropic-ai/claude-code

# Ensure hex and rebar are installed
echo "==> Setting up Elixir tooling..."
mix local.hex --force
mix local.rebar --force

# Check if mix.exs exists (project already initialized)
if [ -f "mix.exs" ]; then
    echo "==> Project found, installing dependencies..."
    # Fix ownership of mounted volumes (they may be owned by root initially)
    sudo chown -R vscode:vscode /workspace/deps /workspace/_build 2>/dev/null || true
    mix deps.get

    echo "==> Setting up database..."
    mix ecto.setup || echo "Database setup skipped (may already exist)"
else
    echo "==> No project found. Run the following to create the Phoenix project:"
    echo ""
    echo "    mix phx.new . --app abyssalwatch --live --no-mailer --no-dashboard"
    echo ""
    echo "Then install Ash dependencies by adding them to mix.exs"
fi

echo "==> Post-create setup complete!"
