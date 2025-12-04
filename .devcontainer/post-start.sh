#!/bin/bash
set -e

echo "==> Running post-start setup..."

# Wait for PostgreSQL to be ready using a simple TCP check
echo "==> Waiting for PostgreSQL..."
timeout=30
counter=0
until nc -z db 5432 2>/dev/null; do
    counter=$((counter + 1))
    if [ $counter -gt $timeout ]; then
        echo "==> Warning: PostgreSQL not available after ${timeout}s, continuing anyway..."
        break
    fi
    sleep 1
done

if [ $counter -le $timeout ]; then
    echo "==> PostgreSQL is ready!"
fi

# If project exists, ensure database is set up
if [ -f "mix.exs" ]; then
    echo "==> Checking database..."
    mix ecto.create 2>/dev/null || true
    mix ecto.migrate 2>/dev/null || true
fi

echo "==> Environment ready!"
echo ""
echo "Useful commands:"
echo "  mix phx.server        - Start Phoenix server (http://localhost:4000)"
echo "  iex -S mix            - Interactive Elixir shell with app loaded"
echo "  iex -S mix phx.server - Phoenix server with IEx shell"
echo "  mix test              - Run tests"
echo "  mix format            - Format code"
echo "  mix credo             - Run static analysis"
echo ""
