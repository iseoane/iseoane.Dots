# iseoane.Dots

Personal dotfiles: zsh, PowerShell 7, Starship, wezterm, herdr, Neovim, and
Claude Code config — one repo shared between a Debian/WSL machine and its
Windows host, with the same terminal experience (Starship prompt, history
suggestions, worktree helpers) on both sides.

Line endings are normalized to LF via `.gitattributes` (CRLF only for
`*.ps1`), so Windows-side commits don't show up as thousands of rewritten
lines.

## Quick start

Set up a machine (run from WSL, so both filesystems are reachable via `/mnt/c`):

```bash
./scripts/apply-to-system.sh
```

After editing a copy-based config directly on the live system, pull it back
before committing:

```bash
./scripts/sync-from-system.sh
git status   # review, then commit
```

Both scripts back up any live file they overwrite (`<file>.bak-<timestamp>`).

### Windows prerequisites (one-time, manual)

| Tool | Install | Why this way |
|------|---------|--------------|
| PowerShell 7 | MSI package (`winget install Microsoft.PowerShell --scope machine`, elevated) | The Store/MSIX build registers `pwsh` only on the *user* PATH, so background processes (herdr server, services, SSH) can't resolve it. The MSI lands in `C:\Program Files\PowerShell\7` on the *machine* PATH. |
| Starship | `winget install Starship.Starship` | Same prompt binary as Debian. Shared config in `starship/starship.toml` (deployed to `~/.config/`) keeps prompts identical and raises `scan_timeout` (see the Starship section). |
| Hack Nerd Font | already required by wezterm | Starship's symbols need it; `wezterm/.wezterm.lua` sets it as the terminal font. |
| Terminal-Icons, DockerCompletion | `Install-Module Terminal-Icons, DockerCompletion -Scope CurrentUser` | PowerShell Gallery modules imported by the PS7 profile (icons in `ls` output, docker completions). |

## What goes where

```
zsh/.zshrc, .zprofile      -> symlinked to $HOME (Debian/WSL)
starship/starship.toml     -> copied to ~/.config/starship.toml on BOTH
                              Debian/WSL and Windows
ssh/config                 -> copied to ~/.ssh/config AND Windows .ssh/config
                              (never keys, never known_hosts)
wezterm/.wezterm.lua       -> copied to Windows $HOME (via /mnt/c)
herdr/config.toml          -> copied to ~/.config/herdr/config.toml AND
                              Windows AppData/Roaming/herdr/config.toml
herdr/scripts/herdr-wt     -> copied to ~/.config/herdr/scripts/ (Debian/WSL)
herdr/scripts/herdr-wt.ps1 -> copied to Documents/WindowsPowerShell/Scripts/
                              AND Documents/PowerShell/Scripts/ (Windows)
herdr/scripts/Microsoft.PowerShell_profile.ps1
                           -> copied to Documents/WindowsPowerShell/ (PS 5.1)
powershell/Microsoft.PowerShell_profile.ps1
                           -> copied to Documents/PowerShell/ (PS 7)
scripts/worktree-management/worktree-mgmt.sh
                           -> copied to ~/.config/worktree-management/ (Debian/WSL)
scripts/worktree-management/worktree-mgmt.ps1
                           -> copied to Documents/PowerShell/Scripts/ (Windows, PS7 only)
scripts/worktree-management/config
                           -> copied to ~/.config/worktree-management/config AND
                              Windows .config/worktree-management/config (both OS
                              roots live in this one versioned file)
claude/CLAUDE.md, settings.json,
agents/, commands/, skills/,
statusline.sh, subagent-statusline.sh
                           -> copied into ~/.claude/ (Debian/WSL)
claude/settings.windows.json,
statusline.ps1, subagent-statusline.ps1,
agents/, commands/, skills/
                           -> copied into Windows .claude/ (via /mnt/c);
                              settings.windows.json lands as settings.json.
                              agents/commands/skills deploy to BOTH sides but
                              sync back from Debian only (canonical origin)
nvim/                      -> copied to ~/.config/nvim (Debian/WSL) AND
                              Windows AppData/Local/nvim (via /mnt/c)
engram/sync.sh             -> copied to ~/.engram-sync/sync.sh (Debian/WSL)
engram/sync.ps1            -> copied to Windows .engram-sync/sync.ps1
                              (via /mnt/c)
```

`claude/settings.local.json` is intentionally NOT versioned — it holds
machine-local overrides per Claude Code convention.

## Strategy: symlink vs copy

- **zsh**: pure config, no secrets or runtime state. **Symlinked** — edit
  anywhere, both sides stay in sync automatically.
- **ssh/config**: host aliases only (`Host`, `HostName`, `User`,
  `IdentityFile` pointers). **Copied**, never symlinked. Private keys
  (`*.pem`, `*.ppk`, `id_*`) and `known_hosts` are gitignored and must never
  be committed — a git history is forever, even in a private repo.
- **claude/**: **copied**. `~/.claude` mixes real config with
  runtime/secrets (`.credentials.json`, logs, sockets, caches); symlinking
  the whole directory would leak credentials into git. Only the config
  subset is versioned. `settings.json` can't be shared across OSes (shell,
  hook commands, and statusline paths differ), so there are two:
  `claude/settings.json` (Debian/WSL, bash statuslines) and
  `claude/settings.windows.json` (Windows, pwsh statuslines and
  node-guarded gitnexus hooks). Each side's statusline scripts are
  versioned next to them.
- **herdr/**, **wezterm/**, **powershell/**, **nvim/**, **starship/**:
  **copied** — they live at different paths per OS (or only exist on one
  side), so a symlink can't cover both. Details below.

### herdr: one config file, two OSes

`herdr/config.toml` is the single source of truth (theme, keybindings,
plugin bindings) and gets copied to both locations. Two settings legitimately
diverge per OS; `apply-to-system.sh` rewrites them on the **Windows copy
only**, and `sync-from-system.sh` never pulls the Windows copy back, so the
overrides can't leak into the repo:

| Setting | Repo / Debian value | Windows override | Why |
|---------|--------------------|-------------------|-----|
| `[update] channel` | `stable` | `preview` | Windows herdr builds are preview-only for now; `herdr update` refuses on `stable`. Revisit once Windows gets stable builds. |
| `[terminal] default_shell` | absent (commented) — panes use `$SHELL` (zsh) | `C:\Program Files\PowerShell\7\pwsh.exe` | Without it, herdr panes on Windows spawn Windows PowerShell 5.1: no Starship, no PSReadLine predictions, no profile. Full path because the herdr server's PATH is not the user's. |

Two more things ride in the shared `config.toml`: the `herdr-file-viewer`
plugin is bound to `prefix+alt+f`, and `[ui.sound] enabled = true` asks herdr
to play its built-in sounds on agent `done`/`blocked` (audio on the Windows
build is beta and may not play yet — under investigation). The official herdr
control skill is also vendored at `.claude/skills/herdr/` as a project-level
Claude Code skill, so `herdr` config work in this repo gets first-class help;
it only activates inside a herdr pane (`HERDR_ENV=1`).

### starship: shared prompt, raised scan_timeout

`starship/starship.toml` is copied to `~/.config/starship.toml` on both OSes.
Beyond matching the prompt, it raises `scan_timeout` to 120 ms (default 30)
and `command_timeout` to 1000 ms. On Windows the directory scan competes with
Sophos on-access AV, and the Google Drive `Z:` mount is a virtual FAT32
filesystem served by GoogleDriveFS (a user-mode driver, slower than kernel
NTFS), so per-file reads there blew past the 30 ms default and made Starship
log `Scanning current directory timed out`. The higher value absorbs it.

### PowerShell: two profiles, one worktree script

Windows runs two PowerShell generations, each with its own profile directory:

- **PS 7** (`powershell/Microsoft.PowerShell_profile.ps1` →
  `Documents/PowerShell/`): the daily shell — used by herdr panes and the
  terminal. Mirrors the zsh setup: Starship prompt, PSReadLine inline history
  suggestions (Ctrl+Space to accept, Up/Down prefix search), a unix
  muscle-memory `ls` shim (`ls -ltr`, `ls -la` just work), and the herdr
  worktree wrappers.
- **PS 5.1** (`herdr/scripts/Microsoft.PowerShell_profile.ps1` →
  `Documents/WindowsPowerShell/`): minimal profile kept for tools that still
  invoke `powershell.exe`; loads only the worktree wrappers.

`herdr-wt.ps1` (the PowerShell port of the bash `herdr-wt`) is deployed to
**both** profile dirs — each profile dot-sources it relative to its own
`$PSScriptRoot`. The PS7 copy is canonical: `sync-from-system.sh` pulls that
one back into the repo. The `lswt`/`crwt`/`openwt`/`rmwt` helpers therefore
exist on both OSes: bash implementation aliased from `.zshrc`, PowerShell
port dot-sourced from the profiles.

Gotcha worth remembering: never `Set-StrictMode` at the top level of a
dot-sourced script — it leaks into the whole interactive session and breaks
third-party prompt hooks (herdr's prompt wrapper, for one). `herdr-wt.ps1`
sets it inside each entry function instead.

### worktree management: herdr-independent, plain `git worktree`

`scripts/worktree-management/` is a second, unrelated worktree toolkit
(`wtls`/`wtnew`/`wtopen`/`wtrm`) that talks to plain `git worktree` directly —
no herdr dependency at all. It exists alongside the herdr-integrated
`lswt`/`crwt`/`openwt`/`rmwt` above, which are left untouched and still work
if herdr is running; the new commands are for worktree management without a
herdr server.

Worktrees are created under a configurable root, one per OS, at
`{root}/worktrees/{repo-name}/{branch}` (a branch like `feature/foo` just
nests into `worktrees/{repo-name}/feature/foo`). `{repo-name}` is resolved
from the git common-dir so it's stable even when you run `wtnew` from inside
an existing worktree rather than the main checkout. Both OS roots live in one
versioned file, `scripts/worktree-management/config` (`linux_root=...` /
`windows_root=...`); a machine prompts once for its own key on first use and
persists the answer to its deployed copy. Run `sync-from-system.sh` afterward
to pull that value back into the repo — once both keys are committed, a
fresh machine gets both pre-seeded by `apply-to-system.sh` and never has to
prompt again.

`wtnew` does a first `git push -u origin <branch>` so the new branch exists on
the remote right away (and `wtls` shows `synced` instead of `local-only`). If
the push fails or the repo has no `origin`, the worktree is still created and a
note explains how to push manually.

`wtrm` removes the worktree and offers to finish the cleanup once the local
branch is deleted: deleting the branch on `origin` too (only when it's merged),
and pruning stale remote-tracking refs via `git fetch --prune origin`. Each
offer explains what it does in plain terms and is skipped under `--force`.

Like `herdr-wt.ps1`, the PowerShell side (`worktree-mgmt.ps1`) is dot-sourced
from the PS7 profile only — `wtopen` needs `Set-Location` to run in the
interactive session, not a subprocess. The bash side (`worktree-mgmt.sh`) is
sourced from `.zshrc` for the same reason (`wtopen` needs a bare `cd`).

### nvim: one config, two OSes

`nvim/` is the GentlemanNvim (LazyVim-based) config. Like herdr, it lives at
different paths per OS (`~/.config/nvim` on Debian/WSL, `%LOCALAPPDATA%\nvim`
on Windows), so it's copied to both locations. `lazy-lock.json` pins plugin
versions, keeping both sides on identical plugins. Sync flows from the Debian
side only: `sync-from-system.sh` pulls `~/.config/nvim` into the repo, and
the Windows copy is always deployed from the repo.

- **wezterm** currently only has a config on the Windows side
  (`/mnt/c/Users/iseoane/.wezterm.lua`); it's copied there via the WSL
  `/mnt/c` bridge.

### engram: cross-machine memory sync hooks

`~/.engram-sync` on each machine is its own git clone of a **separate,
private `engram-data` repo** (not this one) — it holds the append-only
Engram memory chunks (`.engram/chunks/`, `.engram/manifest.json`) that get
pushed/pulled between machines. Only the two hook scripts that drive that
clone are versioned here, as `engram/sync.sh` (Debian/WSL, invoked by
`claude/settings.json`'s SessionStart/Stop hooks) and `engram/sync.ps1`
(Windows, invoked by `claude/settings.windows.json`). `apply-to-system.sh`
copies each script into the existing `~/.engram-sync` clone without touching
its `.git/` or `.engram/` data; `sync-from-system.sh` pulls them back the
same way, skipping the copy on a machine where `~/.engram-sync` hasn't been
cloned yet.
