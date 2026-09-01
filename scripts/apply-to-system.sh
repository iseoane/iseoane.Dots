#!/usr/bin/env bash
# Apply the repo's config to the live system: repo -> machine.
# Run this on a fresh machine (or after pulling changes) to install the dotfiles.
#
# zsh: copied (portable across repository checkout locations).
# claude/herdr/wezterm/nvim: copied (they mix config with runtime state / differ per OS,
# see README for why symlinks aren't used there).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Claude config (CLAUDE.md, settings, agents/commands/skills, statuslines) is
# the one section you don't always want restored from the repo -- live edits
# on a given machine sometimes need to stay live a while before syncing back.
# Everything else here is safe to always reapply, so only this gets a prompt.
RESTORE_CLAUDE="n"
read -rp "Restore claude config from repo (CLAUDE.md, settings, agents/commands/skills, statuslines)? [y/N] " ans || true
case "$ans" in y|Y|yes|YES) RESTORE_CLAUDE="y" ;; esac

install_zsh_plugin() {
  local repository="$1" revision="$2" target="$3"
  if [ ! -d "$target/.git" ]; then
    if [ -e "$target" ]; then
      echo "error: refusing to replace non-Git zsh plugin path: $target" >&2
      return 1
    fi
    git clone --no-checkout "$repository" "$target"
  fi
  if ! git -C "$target" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$target" fetch --depth 1 origin "$revision"
  fi
  git -C "$target" checkout --quiet --detach "$revision"
}

apply_windows_node_config() {
  local manager="$1" target="$2" label="$3"
  if command -v node.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    node.exe "$(wslpath -w "$manager")" apply --target "$(wslpath -w "$target")"
  else
    echo "  $label skipped: native Windows node.exe is required"
  fi
}

has_windows_command() {
  cmd.exe /d /c "where $1 >nul 2>nul" >/dev/null 2>&1
}

if command -v omarchy >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1; then
  echo "== Omarchy terminal prerequisites =="
  # Runs in the caller's visible terminal, so Omarchy may request sudo normally.
  omarchy pkg add zsh starship wezterm ttf-jetbrains-mono-nerd-basic
fi

echo "== zsh (plugins + copy) =="
mkdir -p "$HOME/.zsh"
install_zsh_plugin \
  "https://github.com/zsh-users/zsh-autosuggestions.git" \
  "85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5" \
  "$HOME/.zsh/zsh-autosuggestions"
install_zsh_plugin \
  "https://github.com/zsh-users/zsh-completions.git" \
  "8cd3bd78e8b1f17271cfdd8269074e5557d8d7b8" \
  "$HOME/.zsh/zsh-completions"
copy_with_backup "$REPO_ROOT/zsh/.zshrc" "$HOME/.zshrc"
copy_with_backup "$REPO_ROOT/zsh/.zprofile" "$HOME/.zprofile"
if command -v zsh >/dev/null 2>&1; then
  ZSH_BIN="$(command -v zsh)"
  if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$ZSH_BIN" ]; then
    echo "  changing login shell to $ZSH_BIN (password may be requested)"
    chsh -s "$ZSH_BIN" "$USER"
  fi
fi

echo "== starship (install binary + copy config) =="
# .zshrc unconditionally does `eval "$(starship init zsh)"`, so the binary
# must exist before the config does. Unlike Windows (winget, manual -- see
# README prerequisites), the official installer works unattended here.
if ! command -v starship >/dev/null 2>&1; then
  curl -sS https://starship.rs/install.sh | sh -s -- -y
fi
# Shared prompt config for zsh and PowerShell 7. scan_timeout raised above the
# 30ms default so AV/encryption file-read latency doesn't trip scan warnings.
backup_if_needed "$HOME/.config/starship.toml"
copy "$REPO_ROOT/starship/starship.toml" "$HOME/.config/starship.toml"

echo "== wezterm (copy, linux/wsl side) =="
backup_if_needed "$HOME/.config/wezterm/wezterm.lua"
copy "$REPO_ROOT/wezterm/.wezterm.lua" "$HOME/.config/wezterm/wezterm.lua"
if command -v xdg-terminal-exec >/dev/null 2>&1 && [ -f /usr/share/applications/org.wezfurlong.wezterm.desktop ]; then
  prefer_config_line \
    "org.wezfurlong.wezterm.desktop" \
    "$HOME/.config/xdg-terminals.list"
  echo "  default terminal -> WezTerm"
fi

echo "== Omarchy appearance and Edge flags (non-destructive merge) =="
if command -v omarchy >/dev/null 2>&1; then
  upsert_managed_block \
    "$REPO_ROOT/omarchy/hypr-looknfeel.lua" \
    "$HOME/.config/hypr/looknfeel.lua" \
    "wezterm-blur" \
    "--"
fi
ensure_config_line \
  "$(cat "$REPO_ROOT/edge/microsoft-edge-stable-flags.conf")" \
  "$HOME/.config/microsoft-edge-stable-flags.conf"

echo "== opencode (safe declarative config) =="
node "$REPO_ROOT/opencode/manage.mjs" apply

echo "== pi (config + extensions + native npm dependencies) =="
node "$REPO_ROOT/pi/manage.mjs" apply

echo "== ssh config (copy, never keys) =="
backup_if_needed "$HOME/.ssh/config"
copy "$REPO_ROOT/ssh/config" "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

if [ "$RESTORE_CLAUDE" = "y" ]; then
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
else
  echo "== claude: skipped (not requested) =="
fi

echo "== herdr (copy, debian/wsl side) =="
backup_if_needed "$HOME/.config/herdr/config.toml"
copy "$REPO_ROOT/herdr/config.toml" "$HOME/.config/herdr/config.toml"
backup_if_needed "$HOME/.config/herdr/scripts/herdr-wt"
copy "$REPO_ROOT/herdr/scripts/herdr-wt" "$HOME/.config/herdr/scripts/herdr-wt"
chmod +x "$HOME/.config/herdr/scripts/herdr-wt"

echo "== worktree management (copy, debian/wsl side, herdr-independent) =="
backup_if_needed "$HOME/.config/worktree-management/worktree-mgmt.sh"
copy "$REPO_ROOT/scripts/worktree-management/worktree-mgmt.sh" "$HOME/.config/worktree-management/worktree-mgmt.sh"
backup_if_needed "$HOME/.config/worktree-management/config"
copy "$REPO_ROOT/scripts/worktree-management/config" "$HOME/.config/worktree-management/config"

echo "== nvim (copy, debian/wsl side) =="
backup_if_needed "$HOME/.config/nvim"
copy "$REPO_ROOT/nvim" "$HOME/.config/nvim"

echo "== engram sync hook (copy, debian/wsl side) =="
# ~/.engram-sync is its own git repo (private engram-data remote) that the
# SessionStart/Stop hooks in claude/settings.json AND the SessionStart/SessionEnd
# hooks in codex/hooks.json invoke to push/pull Engram memory chunks between
# machines. Only the hook script is versioned here; the clone's .git/ and
# .engram/ data are machine state, never touched by copy.
mkdir -p "$HOME/.engram-sync"
copy "$REPO_ROOT/engram/sync.sh" "$HOME/.engram-sync/sync.sh"
chmod +x "$HOME/.engram-sync/sync.sh"

echo "== codex (merge, debian/wsl side) =="
# codex/hooks.json is only OUR fragment (SessionStart pull + Stop push), never
# a full snapshot: on this machine the CLI is Orca-wrapped and CODEX_HOME
# points at an Orca-managed runtime dir (~/.local/share/orca/codex-runtime-home/home)
# whose hooks.json already carries Orca's own per-event codex-hook.sh
# dispatcher — a blind copy would destroy that. merge-hooks.py adds our
# entries only if their exact command isn't already present, so this is safe
# to re-run and safe on a plain (non-Orca) machine where CODEX_HOME defaults
# to ~/.codex and the file may not exist yet.
CODEX_HOOKS_TARGET="${CODEX_HOME:-$HOME/.codex}/hooks.json"
mkdir -p "$(dirname "$CODEX_HOOKS_TARGET")"
backup_if_needed "$CODEX_HOOKS_TARGET"
python3 "$REPO_ROOT/codex/merge-hooks.py" "$REPO_ROOT/codex/hooks.json" "$CODEX_HOOKS_TARGET"

if has_windows_mount; then
  echo "== wezterm (copy, native windows side via /mnt/c) =="
  backup_if_needed "$WIN_HOME/.wezterm.lua"
  copy "$REPO_ROOT/wezterm/.wezterm.lua" "$WIN_HOME/.wezterm.lua"

  # Windows Terminal reads per-user fragments from this directory; they add
  # colour schemes without touching settings.json, which stays user-owned (it
  # holds machine-specific profile GUIDs and is rewritten by Terminal's own
  # settings UI). Picking the scheme is still a settings.json / UI choice.
  echo "== windows terminal colour schemes (fragment, windows side via /mnt/c) =="
  WT_FRAGMENTS="$WIN_HOME/AppData/Local/Microsoft/Windows Terminal/Fragments/xeoTheme"
  mkdir -p "$WT_FRAGMENTS"
  backup_if_needed "$WT_FRAGMENTS/xeoTheme.json"
  copy "$REPO_ROOT/windows-terminal/xeoTheme.json" "$WT_FRAGMENTS/xeoTheme.json"

  echo "== herdr (copy, windows side via /mnt/c) =="
  backup_if_needed "$WIN_HOME/AppData/Roaming/herdr/config.toml"
  copy "$REPO_ROOT/herdr/config.toml" "$WIN_HOME/AppData/Roaming/herdr/config.toml"
  # Windows builds are preview-only for now (`herdr update` refuses on stable),
  # so force the channel back to preview on this side regardless of the repo value.
  sed -i 's/^channel = "stable"$/channel = "preview"/' "$WIN_HOME/AppData/Roaming/herdr/config.toml"
  # The shared config already has [terminal]. Add only the Windows shell key;
  # Linux keeps following $SHELL while Windows must avoid PowerShell 5.1.
  sed -i "/^\[terminal\]$/a default_shell = 'C:\\\\Program Files\\\\PowerShell\\\\7\\\\pwsh.exe'" \
    "$WIN_HOME/AppData/Roaming/herdr/config.toml"
  grep -q "^default_shell = '.*pwsh\.exe'$" "$WIN_HOME/AppData/Roaming/herdr/config.toml" ||
    { echo "error: Windows [terminal] default_shell insertion failed" >&2; exit 1; }

  # Link the local herdr-agent-sound plugin on the Windows herdr (sound
  # workaround for herdr issue #1657; the native Windows player is broken).
  # herdr records an absolute path in plugins.json, so it must be (re)linked per
  # machine. Best-effort via Windows interop; if herdr isn't reachable from
  # here, the echo tells you to link it by hand on the Windows side.
  if command -v herdr.exe >/dev/null 2>&1 &&
     HERDR_AGENT_SOUND_WIN="$(wslpath -w "$REPO_ROOT/herdr/plugins/herdr-agent-sound" 2>/dev/null)" &&
     [ -n "$HERDR_AGENT_SOUND_WIN" ] &&
     herdr.exe plugin link "$HERDR_AGENT_SOUND_WIN" >/dev/null 2>&1; then
    echo "  linked herdr-agent-sound plugin (windows)"
  else
    echo "  herdr-agent-sound: link manually on Windows -> herdr plugin link <repo>\\herdr\\plugins\\herdr-agent-sound"
  fi

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

  echo "== worktree management (copy, windows side via /mnt/c, herdr-independent) =="
  # PS7 only -- the legacy WindowsPowerShell (5.1) profile is kept solely for herdr-wt.
  backup_if_needed "$PS7_DIR/Scripts/worktree-mgmt.ps1"
  copy "$REPO_ROOT/scripts/worktree-management/worktree-mgmt.ps1" "$PS7_DIR/Scripts/worktree-mgmt.ps1"
  backup_if_needed "$WIN_HOME/.config/worktree-management/config"
  copy "$REPO_ROOT/scripts/worktree-management/config" "$WIN_HOME/.config/worktree-management/config"

  # Starship reads %USERPROFILE%\.config\starship.toml on Windows too.
  backup_if_needed "$WIN_HOME/.config/starship.toml"
  copy "$REPO_ROOT/starship/starship.toml" "$WIN_HOME/.config/starship.toml"

  echo "== opencode (native windows config) =="
  apply_windows_node_config \
    "$REPO_ROOT/opencode/manage.mjs" \
    "$WIN_HOME/.config/opencode" \
    "opencode windows config"

  echo "== pi (native windows config + npm dependencies) =="
  if has_windows_command pi; then
    apply_windows_node_config \
      "$REPO_ROOT/pi/manage.mjs" \
      "$WIN_HOME/.pi/agent" \
      "pi windows config"
  else
    echo "  pi windows config skipped: Pi is not installed on Windows"
  fi

  if [ "$RESTORE_CLAUDE" = "y" ]; then
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
  else
    echo "== claude (windows side): skipped (not requested) =="
  fi

  echo "== ssh config (copy, windows side via /mnt/c, never keys) =="
  backup_if_needed "$WIN_HOME/.ssh/config"
  copy "$REPO_ROOT/ssh/config" "$WIN_HOME/.ssh/config"

  echo "== nvim (copy, windows side via /mnt/c) =="
  backup_if_needed "$WIN_HOME/AppData/Local/nvim"
  copy "$REPO_ROOT/nvim" "$WIN_HOME/AppData/Local/nvim"

  echo "== engram sync hook (copy, windows side via /mnt/c) =="
  # Windows-side counterpart: settings.windows.json hooks call
  # C:/Users/iseoane/.engram-sync/sync.ps1, its own engram-data clone.
  mkdir -p "$WIN_HOME/.engram-sync"
  copy "$REPO_ROOT/engram/sync.ps1" "$WIN_HOME/.engram-sync/sync.ps1"
else
  echo "== native windows targets skipped: no /mnt/c mount (not running under WSL) =="
fi

echo "Done."
