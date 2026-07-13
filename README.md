# iseoane.Dots

Personal dotfiles: zsh, PowerShell 7, wezterm, herdr, and Claude Code config —
one repo shared between a Debian/WSL machine and its Windows host, with the
same terminal experience (Starship prompt, history suggestions, worktree
helpers) on both sides.

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
| Starship | `winget install Starship.Starship` | Same prompt binary as Debian; both sides use Starship defaults (no `starship.toml`), so prompts match with zero config. |
| Hack Nerd Font | already required by wezterm | Starship's symbols need it; `wezterm/.wezterm.lua` sets it as the terminal font. |
| Terminal-Icons, DockerCompletion | `Install-Module Terminal-Icons, DockerCompletion -Scope CurrentUser` | PowerShell Gallery modules imported by the PS7 profile (icons in `ls` output, docker completions). |

## What goes where

```
zsh/.zshrc, .zprofile      -> symlinked to $HOME (Debian/WSL)
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
claude/CLAUDE.md, settings.json,
agents/, commands/, skills/,
statusline.sh, subagent-statusline.sh
                           -> copied into ~/.claude/ (Debian/WSL)
claude/settings.windows.json,
statusline.ps1, subagent-statusline.ps1
                           -> copied into Windows .claude/ (via /mnt/c);
                              settings.windows.json lands as settings.json
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
- **herdr/**, **wezterm/**, **powershell/**: **copied** — they live at
  different paths per OS (or only exist on one side), so a symlink can't
  cover both. Details below.

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

- **wezterm** currently only has a config on the Windows side
  (`/mnt/c/Users/iseoane/.wezterm.lua`); it's copied there via the WSL
  `/mnt/c` bridge.
