#!/usr/bin/env bash
# Pull the live config back into the repo: machine -> repo.
# Run this before committing, after you've edited the copy-based configs
# (claude, herdr, wezterm, nvim) directly on the live system.
#
# zsh is symlinked, so it never drifts from the repo and isn't handled here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== ssh config (never keys) =="
cp "$HOME/.ssh/config" "$REPO_ROOT/ssh/config"
echo "  synced ssh/config"

echo "== claude =="
cp "$HOME/.claude/CLAUDE.md" "$REPO_ROOT/claude/CLAUDE.md"
cp "$HOME/.claude/settings.json" "$REPO_ROOT/claude/settings.json"
# Guarded: on a machine not yet provisioned with these files, an unguarded cp
# would abort the whole sync under set -e, skipping every later section.
for f in statusline.sh subagent-statusline.sh; do
  if [ -f "$HOME/.claude/$f" ]; then
    cp "$HOME/.claude/$f" "$REPO_ROOT/claude/$f"
  else
    echo "  skip: ~/.claude/$f not found on this machine"
  fi
done
rm -rf "$REPO_ROOT/claude/agents" "$REPO_ROOT/claude/commands" "$REPO_ROOT/claude/skills"
cp -r "$HOME/.claude/agents" "$REPO_ROOT/claude/agents"
cp -r "$HOME/.claude/commands" "$REPO_ROOT/claude/commands"
cp -r "$HOME/.claude/skills" "$REPO_ROOT/claude/skills"
echo "  synced claude/"

echo "== herdr (debian/wsl side) =="
cp "$HOME/.config/herdr/config.toml" "$REPO_ROOT/herdr/config.toml"
cp "$HOME/.config/herdr/scripts/herdr-wt" "$REPO_ROOT/herdr/scripts/herdr-wt"
echo "  synced herdr/config.toml and herdr/scripts/herdr-wt"

echo "== worktree management (debian/wsl side, herdr-independent) =="
cp "$HOME/.config/worktree-management/worktree-mgmt.sh" "$REPO_ROOT/scripts/worktree-management/worktree-mgmt.sh"
echo "  synced scripts/worktree-management/worktree-mgmt.sh"

echo "== nvim (debian/wsl side) =="
if [ -d "$HOME/.config/nvim" ]; then
  backup_if_needed "$REPO_ROOT/nvim"
  copy "$HOME/.config/nvim" "$REPO_ROOT/nvim"
else
  echo "  skipped nvim: $HOME/.config/nvim not found"
fi

echo "== engram sync hook (debian/wsl side) =="
if [ -f "$HOME/.engram-sync/sync.sh" ]; then
  cp "$HOME/.engram-sync/sync.sh" "$REPO_ROOT/engram/sync.sh"
  echo "  synced engram/sync.sh"
else
  echo "  skip: ~/.engram-sync/sync.sh not found"
fi

echo "== codex (debian/wsl side) =="
# No reverse-sync here on purpose: codex/hooks.json is only OUR fragment
# (SessionStart pull + Stop push). The live file at ${CODEX_HOME:-~/.codex}/hooks.json
# also carries entries apply-to-system.sh merged in from elsewhere (e.g. Orca's
# own codex-hook.sh dispatcher on this machine) that must never land in the repo.
# Edit codex/hooks.json directly, then re-run apply-to-system.sh to redeploy.
echo "  skip: codex/hooks.json is edited directly, not synced back from the live file"

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

  echo "== worktree management (windows side via /mnt/c, herdr-independent) =="
  cp "$PS7_DIR/Scripts/worktree-mgmt.ps1" "$REPO_ROOT/scripts/worktree-management/worktree-mgmt.ps1"
  # Each OS only knows/writes its own key, so merge rather than overwrite: pull
  # linux_root from the Debian side's config and windows_root from the Windows
  # side's, replacing only the matching line in the repo copy (comment header
  # and the other OS's key are left untouched).
  WT_CONFIG="$REPO_ROOT/scripts/worktree-management/config"
  LINUX_ROOT_VAL=$(grep -E '^linux_root=' "$HOME/.config/worktree-management/config" 2>/dev/null | tail -1 | cut -d= -f2-)
  WIN_ROOT_VAL=$(grep -E '^windows_root=' "$WIN_HOME/.config/worktree-management/config" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ -n "$LINUX_ROOT_VAL" ] && sed -i "s#^linux_root=.*#linux_root=${LINUX_ROOT_VAL}#" "$WT_CONFIG"
  [ -n "$WIN_ROOT_VAL" ] && sed -i "s#^windows_root=.*#windows_root=${WIN_ROOT_VAL}#" "$WT_CONFIG"
  echo "  synced scripts/worktree-management/worktree-mgmt.ps1 and config"

  echo "== claude (windows side via /mnt/c) =="
  # Same guard rationale as the Debian statuslines above.
  if [ -f "$WIN_HOME/.claude/settings.json" ]; then
    cp "$WIN_HOME/.claude/settings.json" "$REPO_ROOT/claude/settings.windows.json"
  else
    echo "  skip: windows .claude/settings.json not found"
  fi
  for f in statusline.ps1 subagent-statusline.ps1; do
    if [ -f "$WIN_HOME/.claude/$f" ]; then
      cp "$WIN_HOME/.claude/$f" "$REPO_ROOT/claude/$f"
    else
      echo "  skip: windows .claude/$f not found"
    fi
  done
  echo "  synced claude/settings.windows.json and windows statuslines"

  echo "== engram sync hook (windows side via /mnt/c) =="
  if [ -f "$WIN_HOME/.engram-sync/sync.ps1" ]; then
    cp "$WIN_HOME/.engram-sync/sync.ps1" "$REPO_ROOT/engram/sync.ps1"
    echo "  synced engram/sync.ps1"
  else
    echo "  skip: windows .engram-sync/sync.ps1 not found"
  fi
else
  echo "== wezterm skipped: no /mnt/c mount (not running under WSL) =="
fi

echo "Done. Review with 'git status' / 'git diff' before committing."
