#!/bin/bash
set -e

echo "==> Running post-start setup..."

# Fix Claude Code and OpenCode host path references.
# When ~/.claude or ~/.config/opencode is mounted from the host, config files
# contain absolute paths using the host username (e.g. /home/tng/.claude/...)
# which don't resolve in the container where the user is "vscode". Create a
# symlink from the host home directory to the container home so these paths
# resolve.
CONTAINER_HOME="$(eval echo ~)"

# Handle Claude Code config
if [ -d "$CONTAINER_HOME/.claude" ]; then
    MARKETPLACE_CFG="$CONTAINER_HOME/.claude/plugins/known_marketplaces.json"
    INSTALLED_CFG="$CONTAINER_HOME/.claude/plugins/installed_plugins.json"
    HOST_HOMES=$(
        {
            [ -f "$MARKETPLACE_CFG" ] && grep -oP '"installLocation":\s*"\K/home/[^/]+' "$MARKETPLACE_CFG"
            [ -f "$INSTALLED_CFG" ]   && grep -oP '"installPath":\s*"\K/home/[^/]+' "$INSTALLED_CFG"
        } 2>/dev/null | sort -u
    )
    for HOST_HOME in $HOST_HOMES; do
        if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "$CONTAINER_HOME" ] && [ ! -e "$HOST_HOME" ]; then
            echo "🔗 Creating symlink $HOST_HOME -> $CONTAINER_HOME (Claude Code host path fix)"
            sudo ln -sfn "$CONTAINER_HOME" "$HOST_HOME"
        fi
    done
fi

# Handle OpenCode config (XDG path ~/.config/opencode)
if [ -d "$CONTAINER_HOME/.config/opencode" ]; then
    HOST_HOME=""
    for item in "$CONTAINER_HOME/.config/opencode"/*; do
        if [ -L "$item" ] && [ ! -e "$item" ]; then
            HOST_HOME=$(readlink "$item" | grep -oP '^/home/[^/]+' || true)
            [ -n "$HOST_HOME" ] && break
        fi
    done
    if [ -z "$HOST_HOME" ]; then
        OPENCODE_CONFIG="$CONTAINER_HOME/.config/opencode/opencode.json"
        if [ -f "$OPENCODE_CONFIG" ]; then
            HOST_HOME=$(grep -oP '"/home/[^"]+' "$OPENCODE_CONFIG" | head -1 | tr -d '"' | grep -oP '/home/[^/]+' || true)
        fi
    fi
    if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "$CONTAINER_HOME" ] && [ ! -e "$HOST_HOME" ]; then
        echo "🔗 Creating symlink $HOST_HOME -> $CONTAINER_HOME (OpenCode host path fix)"
        sudo ln -sfn "$CONTAINER_HOME" "$HOST_HOME"
    fi
fi

# Remove Windows credential helper if present (copied from host .gitconfig)
if grep -q "credential-manager.exe" "$CONTAINER_HOME/.gitconfig" 2>/dev/null; then
    echo "🔧 Removing Windows credential helper from git config..."
    git config --global --unset credential.helper 2>/dev/null || true
fi

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
