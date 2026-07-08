#!/usr/bin/env bash
# Apply the repo's config to the live system: repo -> machine.
# Run this on a fresh machine (or after pulling changes) to install the dotfiles.
#
# zsh: symlinked (live edits stay in sync with the repo automatically).
# claude/herdr/wezterm: copied (they mix config with runtime state / differ per OS,
# see README for why symlinks aren't used there).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== zsh (symlink) =="
symlink "$REPO_ROOT/zsh/.zshrc" "$HOME/.zshrc"
symlink "$REPO_ROOT/zsh/.zprofile" "$HOME/.zprofile"

echo "== claude (copy) =="
backup_if_needed "$HOME/.claude/CLAUDE.md"
copy "$REPO_ROOT/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
backup_if_needed "$HOME/.claude/settings.json"
copy "$REPO_ROOT/claude/settings.json" "$HOME/.claude/settings.json"
backup_if_needed "$HOME/.claude/agents"
copy "$REPO_ROOT/claude/agents" "$HOME/.claude/agents"
backup_if_needed "$HOME/.claude/commands"
copy "$REPO_ROOT/claude/commands" "$HOME/.claude/commands"
backup_if_needed "$HOME/.claude/skills"
copy "$REPO_ROOT/claude/skills" "$HOME/.claude/skills"

echo "== herdr (copy, debian/wsl side) =="
backup_if_needed "$HOME/.config/herdr/config.toml"
copy "$REPO_ROOT/herdr/config.toml" "$HOME/.config/herdr/config.toml"

if has_windows_mount; then
  echo "== wezterm (copy, windows side via /mnt/c) =="
  backup_if_needed "$WIN_HOME/.wezterm.lua"
  copy "$REPO_ROOT/wezterm/.wezterm.lua" "$WIN_HOME/.wezterm.lua"
else
  echo "== wezterm skipped: no /mnt/c mount (not running under WSL) =="
fi

echo "Done."
