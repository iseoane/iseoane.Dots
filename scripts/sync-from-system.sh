#!/usr/bin/env bash
# Pull the live config back into the repo: machine -> repo.
# Run this before committing, after you've edited the copy-based configs
# (claude, herdr, wezterm) directly on the live system.
#
# zsh is symlinked, so it never drifts from the repo and isn't handled here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== ssh config (never keys) =="
cp "$HOME/.ssh/config" "$REPO_ROOT/ssh/config"
echo "  synced ssh/config"

echo "== claude =="
cp "$HOME/.claude/CLAUDE.md" "$REPO_ROOT/claude/CLAUDE.md"
cp "$HOME/.claude/settings.json" "$REPO_ROOT/claude/settings.json"
rm -rf "$REPO_ROOT/claude/agents" "$REPO_ROOT/claude/commands" "$REPO_ROOT/claude/skills"
cp -r "$HOME/.claude/agents" "$REPO_ROOT/claude/agents"
cp -r "$HOME/.claude/commands" "$REPO_ROOT/claude/commands"
cp -r "$HOME/.claude/skills" "$REPO_ROOT/claude/skills"
echo "  synced claude/"

echo "== herdr (debian/wsl side) =="
cp "$HOME/.config/herdr/config.toml" "$REPO_ROOT/herdr/config.toml"
cp "$HOME/.config/herdr/scripts/herdr-wt" "$REPO_ROOT/herdr/scripts/herdr-wt"
echo "  synced herdr/config.toml and herdr/scripts/herdr-wt"

if has_windows_mount; then
  echo "== wezterm (windows side via /mnt/c) =="
  cp "$WIN_HOME/.wezterm.lua" "$REPO_ROOT/wezterm/.wezterm.lua"
  echo "  synced wezterm/.wezterm.lua"

  echo "== herdr powershell scripts (windows side via /mnt/c) =="
  # herdr-wt.ps1 is deployed to BOTH PowerShell dirs; the PS7 copy is canonical
  # (it's the shell herdr and the terminal actually run), so sync from there.
  PS_DIR="$WIN_HOME/Documents/WindowsPowerShell"
  PS7_DIR="$WIN_HOME/Documents/PowerShell"
  cp "$PS7_DIR/Scripts/herdr-wt.ps1" "$REPO_ROOT/herdr/scripts/herdr-wt.ps1"
  cp "$PS_DIR/Microsoft.PowerShell_profile.ps1" "$REPO_ROOT/herdr/scripts/Microsoft.PowerShell_profile.ps1"
  echo "  synced herdr/scripts/herdr-wt.ps1 and Microsoft.PowerShell_profile.ps1"

  echo "== powershell 7 profile (windows side via /mnt/c) =="
  cp "$PS7_DIR/Microsoft.PowerShell_profile.ps1" "$REPO_ROOT/powershell/Microsoft.PowerShell_profile.ps1"
  echo "  synced powershell/Microsoft.PowerShell_profile.ps1"
else
  echo "== wezterm skipped: no /mnt/c mount (not running under WSL) =="
fi

echo "Done. Review with 'git status' / 'git diff' before committing."
