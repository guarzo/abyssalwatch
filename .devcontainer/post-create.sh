#!/bin/bash
set -e

echo "==> Running post-create setup..."

# Ensure binaries from ~/.local, ~/.opencode, ~/.dotfiles, and ~/.pi are on PATH
# for this script and future shells.
PATH_LINE='export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.dotfiles/bin:$HOME/.pi/agent/bin:$PATH"'
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.dotfiles/bin:$HOME/.pi/agent/bin:$PATH"
if ! grep -qF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
    echo "$PATH_LINE" >> "$HOME/.bashrc"
fi
if [ -f "$HOME/.zshrc" ] && ! grep -qF "$PATH_LINE" "$HOME/.zshrc"; then
    echo "$PATH_LINE" >> "$HOME/.zshrc"
fi

# Source ~/.dotfiles zsh config files (mirrors slabledger zshrc behavior).
# The dotfiles repo at ~/.dotfiles publishes *.zsh files (path/aliases/env)
# meant to be sourced by interactive shells.
DOTFILES_BLOCK='# Load dotfiles from host (if mounted)
if [[ -d "$HOME/.dotfiles" ]]; then
  export DOTFILES="$HOME/.dotfiles"
  typeset -U config_files
  config_files=($DOTFILES/**/*.zsh)
  for file in ${(M)config_files:#*/path.zsh}; do source $file 2>/dev/null; done
  for file in ${${config_files:#*/path.zsh}:#*/completion.zsh}; do source $file 2>/dev/null; done
  unset config_files
fi'
if [ -f "$HOME/.zshrc" ] && ! grep -q 'Load dotfiles from host' "$HOME/.zshrc"; then
    printf '\n%s\n' "$DOTFILES_BLOCK" >> "$HOME/.zshrc"
fi

# Install Claude Code CLI
echo "==> Installing Claude Code CLI..."
if ! curl -fsSL https://claude.ai/install.sh | bash; then
    echo "⚠️  Claude Code CLI installation failed, continuing..."
fi

# Restore Claude config from backup if the main file is missing but a backup exists
CLAUDE_CFG="$HOME/.claude.json"
if [ ! -f "$CLAUDE_CFG" ]; then
    BACKUP=$(ls -t "$HOME/.claude/backups/.claude.json.backup."* 2>/dev/null | head -1)
    if [ -n "$BACKUP" ]; then
        echo "==> Restoring Claude config from backup..."
        cp "$BACKUP" "$CLAUDE_CFG"
    fi
fi

# Install OpenCode CLI
echo "==> Installing OpenCode CLI..."
if ! curl -fsSL https://opencode.ai/install | bash; then
    echo "⚠️  OpenCode CLI installation failed, continuing..."
fi

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
