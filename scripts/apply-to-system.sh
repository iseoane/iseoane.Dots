#!/usr/bin/env bash
# Apply the repo's config to the live system: repo -> machine.
# Run this on a fresh machine (or after pulling changes) to install the dotfiles.
#
# zsh: symlinked (live edits stay in sync with the repo automatically).
# claude/herdr/wezterm/nvim: copied (they mix config with runtime state / differ per OS,
# see README for why symlinks aren't used there).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== zsh (symlink) =="
symlink "$REPO_ROOT/zsh/.zshrc" "$HOME/.zshrc"
symlink "$REPO_ROOT/zsh/.zprofile" "$HOME/.zprofile"

echo "== starship (copy) =="
# Shared prompt config for zsh and PowerShell 7. scan_timeout raised above the
# 30ms default so AV/encryption file-read latency doesn't trip scan warnings.
backup_if_needed "$HOME/.config/starship.toml"
copy "$REPO_ROOT/starship/starship.toml" "$HOME/.config/starship.toml"

echo "== ssh config (copy, never keys) =="
backup_if_needed "$HOME/.ssh/config"
copy "$REPO_ROOT/ssh/config" "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

echo "== claude (copy) =="
backup_if_needed "$HOME/.claude/CLAUDE.md"
copy "$REPO_ROOT/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
backup_if_needed "$HOME/.claude/settings.json"
copy "$REPO_ROOT/claude/settings.json" "$HOME/.claude/settings.json"
backup_if_needed "$HOME/.claude/statusline.sh"
copy "$REPO_ROOT/claude/statusline.sh" "$HOME/.claude/statusline.sh"
backup_if_needed "$HOME/.claude/subagent-statusline.sh"
copy "$REPO_ROOT/claude/subagent-statusline.sh" "$HOME/.claude/subagent-statusline.sh"
chmod +x "$HOME/.claude/statusline.sh" "$HOME/.claude/subagent-statusline.sh"
backup_if_needed "$HOME/.claude/agents"
copy "$REPO_ROOT/claude/agents" "$HOME/.claude/agents"
backup_if_needed "$HOME/.claude/commands"
copy "$REPO_ROOT/claude/commands" "$HOME/.claude/commands"
backup_if_needed "$HOME/.claude/skills"
copy "$REPO_ROOT/claude/skills" "$HOME/.claude/skills"

echo "== herdr (copy, debian/wsl side) =="
backup_if_needed "$HOME/.config/herdr/config.toml"
copy "$REPO_ROOT/herdr/config.toml" "$HOME/.config/herdr/config.toml"
backup_if_needed "$HOME/.config/herdr/scripts/herdr-wt"
copy "$REPO_ROOT/herdr/scripts/herdr-wt" "$HOME/.config/herdr/scripts/herdr-wt"
chmod +x "$HOME/.config/herdr/scripts/herdr-wt"

echo "== nvim (copy, debian/wsl side) =="
backup_if_needed "$HOME/.config/nvim"
copy "$REPO_ROOT/nvim" "$HOME/.config/nvim"

if has_windows_mount; then
  echo "== wezterm (copy, windows side via /mnt/c) =="
  backup_if_needed "$WIN_HOME/.wezterm.lua"
  copy "$REPO_ROOT/wezterm/.wezterm.lua" "$WIN_HOME/.wezterm.lua"

  echo "== herdr (copy, windows side via /mnt/c) =="
  backup_if_needed "$WIN_HOME/AppData/Roaming/herdr/config.toml"
  copy "$REPO_ROOT/herdr/config.toml" "$WIN_HOME/AppData/Roaming/herdr/config.toml"
  # Windows builds are preview-only for now (`herdr update` refuses on stable),
  # so force the channel back to preview on this side regardless of the repo value.
  sed -i 's/^channel = "stable"$/channel = "preview"/' "$WIN_HOME/AppData/Roaming/herdr/config.toml"
  # Uncomment the WINDOWS ONLY [terminal] default_shell block so herdr panes
  # spawn PowerShell 7 instead of Windows PowerShell 5.1. The repo copy keeps
  # it commented because the same file is applied on Debian/WSL, where that
  # path doesn't exist and would break pane spawning.
  sed -i -e 's/^# \(\[terminal\]\)$/\1/' -e "s/^# \(default_shell = '.*pwsh\.exe'\)$/\1/" \
    "$WIN_HOME/AppData/Roaming/herdr/config.toml"
  # sed exits 0 even when nothing matches; fail loudly if the commented block
  # ever drifts and the uncomment silently no-ops (panes would fall back to 5.1).
  grep -q '^\[terminal\]$' "$WIN_HOME/AppData/Roaming/herdr/config.toml" &&
    grep -q "^default_shell = '.*pwsh\.exe'$" "$WIN_HOME/AppData/Roaming/herdr/config.toml" ||
    { echo "error: [terminal] default_shell uncomment did not take effect" >&2; exit 1; }

  PS_DIR="$WIN_HOME/Documents/WindowsPowerShell"
  backup_if_needed "$PS_DIR/Scripts/herdr-wt.ps1"
  copy "$REPO_ROOT/herdr/scripts/herdr-wt.ps1" "$PS_DIR/Scripts/herdr-wt.ps1"
  backup_if_needed "$PS_DIR/Microsoft.PowerShell_profile.ps1"
  copy "$REPO_ROOT/herdr/scripts/Microsoft.PowerShell_profile.ps1" "$PS_DIR/Microsoft.PowerShell_profile.ps1"

  echo "== powershell 7 profile (copy, windows side via /mnt/c) =="
  # PS7 has its own profile dir; herdr-wt.ps1 is deployed here too because the
  # profile dot-sources it relative to $PSScriptRoot. Requires PS7 installed
  # from the MSI package and Starship on PATH (see README, Windows prerequisites).
  PS7_DIR="$WIN_HOME/Documents/PowerShell"
  backup_if_needed "$PS7_DIR/Microsoft.PowerShell_profile.ps1"
  copy "$REPO_ROOT/powershell/Microsoft.PowerShell_profile.ps1" "$PS7_DIR/Microsoft.PowerShell_profile.ps1"
  backup_if_needed "$PS7_DIR/Scripts/herdr-wt.ps1"
  copy "$REPO_ROOT/herdr/scripts/herdr-wt.ps1" "$PS7_DIR/Scripts/herdr-wt.ps1"

  # Starship reads %USERPROFILE%\.config\starship.toml on Windows too.
  backup_if_needed "$WIN_HOME/.config/starship.toml"
  copy "$REPO_ROOT/starship/starship.toml" "$WIN_HOME/.config/starship.toml"

  echo "== claude (copy, windows side via /mnt/c) =="
  # Windows keeps its OWN settings.json (pwsh statuslines, C:/ hook paths,
  # node-guarded gitnexus hooks) — versioned as claude/settings.windows.json.
  backup_if_needed "$WIN_HOME/.claude/settings.json"
  copy "$REPO_ROOT/claude/settings.windows.json" "$WIN_HOME/.claude/settings.json"
  backup_if_needed "$WIN_HOME/.claude/statusline.ps1"
  copy "$REPO_ROOT/claude/statusline.ps1" "$WIN_HOME/.claude/statusline.ps1"
  backup_if_needed "$WIN_HOME/.claude/subagent-statusline.ps1"
  copy "$REPO_ROOT/claude/subagent-statusline.ps1" "$WIN_HOME/.claude/subagent-statusline.ps1"
  # Windows gets the same agents/commands/skills as Debian; the repo is the
  # source of truth for both, but sync-from-system.sh only pulls them back
  # from the Debian side (single canonical origin).
  backup_if_needed "$WIN_HOME/.claude/agents"
  copy "$REPO_ROOT/claude/agents" "$WIN_HOME/.claude/agents"
  backup_if_needed "$WIN_HOME/.claude/commands"
  copy "$REPO_ROOT/claude/commands" "$WIN_HOME/.claude/commands"
  backup_if_needed "$WIN_HOME/.claude/skills"
  copy "$REPO_ROOT/claude/skills" "$WIN_HOME/.claude/skills"

  echo "== ssh config (copy, windows side via /mnt/c, never keys) =="
  backup_if_needed "$WIN_HOME/.ssh/config"
  copy "$REPO_ROOT/ssh/config" "$WIN_HOME/.ssh/config"

  echo "== nvim (copy, windows side via /mnt/c) =="
  backup_if_needed "$WIN_HOME/AppData/Local/nvim"
  copy "$REPO_ROOT/nvim" "$WIN_HOME/AppData/Local/nvim"
else
  echo "== wezterm/herdr(win) skipped: no /mnt/c mount (not running under WSL) =="
fi

echo "Done."
