# iseoane.Dots

Personal dotfiles: zsh, wezterm, herdr, and Claude Code config — shared
between a Debian/WSL machine and Windows.

## Strategy

Not everything is handled the same way:

- **zsh** (`.zshrc`, `.zprofile`): pure config, no secrets or runtime state.
  Installed as **symlinks** — edit anywhere, both sides stay in sync.
- **ssh/config**: only the host aliases (`Host`, `HostName`, `User`,
  `IdentityFile` pointers), **copied**, never symlinked. Private keys
  (`*.pem`, `*.ppk`, `id_*`) and `known_hosts` are explicitly gitignored and
  must never be committed — a git history is forever, even in a private repo.
- **claude/**, **herdr/**, **wezterm/**: **copied**, not symlinked, via the
  scripts below. Reasons:
  - `~/.claude` mixes real config (`CLAUDE.md`, `agents/`, `commands/`,
    `skills/`, `settings.json`) with runtime/secrets (`.credentials.json`,
    logs, sockets, caches). Symlinking the whole directory would leak
    credentials into git. Only the config subset is versioned.
  - `herdr` config lives at different paths per OS (`~/.config/herdr/config.toml`
    on Debian/WSL, `AppData/Roaming/herdr/config.toml` on Windows), so a
    symlink can't cover both. `herdr/config.toml` is the single source of
    truth and gets **copied to both locations** — Debian's fully customized
    config (theme, keybindings, plugin bindings) plus `[update] channel =
    "preview"` merged in from what Windows had. The `lswt`/`crwt`/`openwt`/`rmwt` worktree helpers exist on both sides as
    separate implementations: `herdr/scripts/herdr-wt` (bash, aliased from
    `.zshrc`) on Debian/WSL, and `herdr/scripts/herdr-wt.ps1` +
    `Microsoft.PowerShell_profile.ps1` (the PowerShell port, dot-sourced from
    the profile) on Windows.
  - `wezterm` currently only has a config on the Windows side
    (`/mnt/c/Users/iseoane/.wezterm.lua`); it's copied there via the WSL
    `/mnt/c` bridge.

## Layout

```
zsh/.zshrc, .zprofile      -> symlinked to $HOME
ssh/config                 -> copied to ~/.ssh/config AND Windows .ssh/config
                              (never keys, never known_hosts)
wezterm/.wezterm.lua       -> copied to Windows $HOME (via /mnt/c)
herdr/config.toml          -> copied to ~/.config/herdr/config.toml AND
                              Windows AppData/Roaming/herdr/config.toml
herdr/scripts/herdr-wt     -> copied to ~/.config/herdr/scripts/ (Debian/WSL)
herdr/scripts/herdr-wt.ps1,
Microsoft.PowerShell_profile.ps1
                           -> copied to Documents/WindowsPowerShell/ (Windows)
claude/CLAUDE.md
claude/settings.json
claude/agents/
claude/commands/
claude/skills/             -> copied into ~/.claude/
```

`claude/settings.local.json` is intentionally NOT versioned — it's meant to
hold machine-local overrides per Claude Code convention.

## Usage

On a machine you want to set up (must be run from WSL so it can reach both
the Debian and the Windows filesystem via `/mnt/c`):

```bash
./scripts/apply-to-system.sh
```

After editing a copy-based config directly on the live system (e.g. tweaking
`~/.config/herdr/config.toml` or `~/.claude/settings.json`), pull the changes
back into the repo before committing:

```bash
./scripts/sync-from-system.sh
git status
git add -A && git commit -m "sync: update config"
```

Existing live files are backed up (`<file>.bak-<timestamp>`) before being
overwritten by either script.
