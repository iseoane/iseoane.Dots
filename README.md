# iseoane.Dots

Personal dotfiles: zsh, wezterm, herdr, and Claude Code config — shared
between a Debian/WSL machine and Windows.

## Strategy

Not everything is handled the same way:

- **zsh** (`.zshrc`, `.zprofile`): pure config, no secrets or runtime state.
  Installed as **symlinks** — edit anywhere, both sides stay in sync.
- **claude/**, **herdr/**, **wezterm/**: **copied**, not symlinked, via the
  scripts below. Reasons:
  - `~/.claude` mixes real config (`CLAUDE.md`, `agents/`, `commands/`,
    `skills/`, `settings.json`) with runtime/secrets (`.credentials.json`,
    logs, sockets, caches). Symlinking the whole directory would leak
    credentials into git. Only the config subset is versioned.
  - `herdr` has a different install layout on Windows (binary + installer
    state) vs Debian/WSL (`config.toml` + sockets). There's no single file
    both sides share, so only the Debian `config.toml` is versioned; syncing
    across OS is a copy operation, not a link.
  - `wezterm` currently only has a config on the Windows side
    (`/mnt/c/Users/iseoane/.wezterm.lua`); it's copied there via the WSL
    `/mnt/c` bridge.

## Layout

```
zsh/.zshrc, .zprofile      -> symlinked to $HOME
wezterm/.wezterm.lua       -> copied to Windows $HOME (via /mnt/c)
herdr/config.toml          -> copied to ~/.config/herdr/config.toml
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
