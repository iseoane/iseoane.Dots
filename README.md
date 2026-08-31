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
windows-terminal/gentleman.json
                           -> copied to Windows AppData/Local/Microsoft/
                              Windows Terminal/Fragments/Gentleman.Dots/
                              (adds the colour schemes; settings.json itself
                              stays user-owned and is never written)
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
codex/hooks.json           -> merged (via codex/merge-hooks.py) into
                              ${CODEX_HOME:-~/.codex}/hooks.json (Debian/WSL
                              only; Codex isn't provisioned on the Windows
                              side yet)
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

### colour theme: Gentleman, across wezterm, Starship and herdr

wezterm, Starship and herdr all render the **Gentleman** palette -- the same
one `gentle-ai` injects into its agents, and the one `nvim` already uses via
the `gentleman-kanagawa-blur` colorscheme (`nvim/lua/plugins/colorscheme.lua`).

The canonical source is `Gentleman-Programming/gentleman-kanagawa-blur`:
`lua/gentleman_kanagawa_blur/variant.lua` for the semantic roles, and
`extras/ghostty/gentleman-kanagawa-blur` for the 16 ANSI slots plus
background/foreground/cursor/selection. (Two traps: that repo's
`extras/alacritty/` and `extras/kitty/` files were inherited from the upstream
`oldworld.nvim` and do *not* carry the Gentleman hexes; and `gentle-ai`'s
`internal/tui/styles/styles.go` is Rose Pine -- that's its installer chrome,
not the theme. The theme gentle-ai owns is the one it injects in
`internal/components/theme/inject.go`.)

Each tool expresses it differently, because each supports a different amount:

| Tool | Mechanism | Selectable? |
|------|-----------|-------------|
| wezterm | `config.color_schemes` in `.wezterm.lua`, with `config.color_scheme` picking one | Yes -- `"Gentleman Blur"` (active), `"Gentleman Sakura"`, or any wezterm built-in such as the previous `"rose-pine-moon"` |
| Windows Terminal | `windows-terminal/gentleman.json`, a **fragment** deployed to `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\Gentleman.Dots\` | Yes -- `Gentleman` (active) or `Gentleman Sakura`, pickable in the settings UI |
| Starship | `[palettes.*]` in `starship.toml`, selected by `palette = ...` | Yes -- `gentleman-blur` (active) or `gentleman-sakura`; comment `palette` out to fall back to the terminal's ANSI colours |
| Neovim | the `gentleman-kanagawa-blur` colorscheme (`nvim/lua/plugins/colorscheme.lua`) | Yes -- it's the LazyVim `colorscheme` opt |
| herdr | `[theme.custom]` token overrides on top of a built-in base | **No** -- herdr 0.8.2 has a fixed list of built-in theme names and no user-defined ones, so the preset is a commented block you toggle by hand |

Two details worth knowing before editing these:

- The schemes are defined **inline in `.wezterm.lua`**, not as a
  `colors/*.toml` file, because only `.wezterm.lua` itself is copied to the
  Windows `$HOME` (see the deployment map above) -- a sidecar file wouldn't
  ship. For the same reason the old top-level `config.colors` block is gone:
  it overrode the scheme's `selection_bg`/`selection_fg` entry-by-entry, so
  rose-pine's selection would have survived into the new theme.
- The Starship palette deliberately reuses Starship's **standard colour
  names** (`green`, `cyan`, `bright-black`, ...). A palette entry shadows the
  built-in of the same name, so the default prompt -- which styles its modules
  as `bold green`, `bold cyan` and so on -- picks the theme up with no module
  rewrites at all. Verified on starship 1.26.0; if a future version drops that
  shadowing, every module needs an explicit `style =` instead.

**Shell syntax highlighting is themed by role, from fish.** PSReadLine and
zsh-syntax-highlighting both ship defaults that ignore the palette -- most
visibly PSReadLine's `Command`, which is plain `Yellow`, so every typed command
came out in `#FFE066`. In this palette yellow belongs to **strings**; commands
are cyan. Both shells now carry the role assignment from Gentleman.Dots'
`GentlemanFish/fish/config.fish`, in `powershell/Microsoft.PowerShell_profile.ps1`
(`Set-PSReadLineOption -Colors`) and `zsh/.zshrc` (`ZSH_HIGHLIGHT_STYLES`, set
after the plugin is sourced so it wins). Two roles fish has no equivalent for
depart from `variant.lua` on purpose, both to avoid colliding with a role
already in use: `Variable` (its `#C4746E` sits only dE 17 from the error
colour) and `Type` (its `#8FB8DD` is dE 7 from `Parameter`, i.e.
indistinguishable). This changes no palette value -- only which role uses which.

**Windows Terminal is deliberately only half-managed.** The repo ships the
schemes as a fragment, which is the supported way to add colours without
touching `settings.json` -- that file holds machine-specific profile GUIDs and
paths and is rewritten by Terminal's own settings UI, so versioning it whole
would be fragile. Which scheme is *active* therefore stays a `settings.json` /
UI choice and is not reapplied by `apply-to-system.sh` -- and so does
transparency, since `opacity` and `useAcrylic` live on `profiles.defaults` and
a fragment cannot set those. Both are currently `opacity: 85` + `useAcrylic`,
matching wezterm's `window_background_opacity = 0.85`; keep the two in step if
you retune either. Note also that a scheme
of the same name inside `settings.json` shadows the fragment's; the inline
`Gentleman` entry there is byte-identical, so it makes no difference.

**The reference for the per-role values is Gentleman.Dots' fish config**
(`GentlemanFish/fish/config.fish`, byte-identical to the colorscheme's own
`extras/fish/blur.fish`). It is the one place upstream writes the palette out
by semantic role rather than by ANSI slot, so it settles what "the Gentleman
red" actually is. Every role it defines -- foreground, selection, comment, red,
yellow, green, cyan and its `pink` (the magenta slot) -- is used verbatim here.

It defines no **blue**, though, so that one value comes from upstream's herdr
config: `#6FA0AF`, a muted cyan, rather than the brighter `#7FB4CA` its ghostty
export uses. `#7FB4CA` survives only on bright cyan (slot 14). Note that herdr
and fish do *not* otherwise agree: herdr's `yellow` is `#DEBA87`, which is
fish's **orange**, because herdr's fixed six-token chrome has no orange slot to
put it in. fish wins that one -- yellow stays `#FFE066`.

**One upstream inconsistency is also corrected, on ANSI slots 5 and 13.**
`variant.lua` defines `purple` (`#A3B5D6`) and `magenta` (`#FF8DD7`) as separate
colours, and upstream is not self-consistent about which one lands in the ANSI
magenta slots: its ghostty export uses magenta, its Neovim `:terminal` mapping
uses purple. fish maps its `pink` (`#FF8DD7`) to magenta, so **magenta** wins
here and all five surfaces render one identical 16-colour palette:

- `nvim/lua/plugins/colorscheme.lua` re-sets `terminal_color_5`/`13` in an
  `init()` autocmd after the colorscheme loads, so a `:terminal` buffer inside
  Neovim matches the shell outside it.
- `starship.toml`'s `purple` entry is `#FF8DD7`, not `#A3B5D6` -- Starship's
  `purple` *is* the ANSI 5 slot. The muted one is still available in the palette
  as `soft-purple` if you'd rather have lavender on `git_branch`.

herdr's `accent` and `blue` are both `#6FA0AF`, copied verbatim from
Gentleman.Dots' own `herdr/config.toml`; as explained above, that value is now
the blue everywhere else too.

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

On Debian/WSL, `apply-to-system.sh` installs the `starship` binary itself
(official installer, unattended) if it's not already on PATH -- `.zshrc`
unconditionally does `eval "$(starship init zsh)"`, so a fresh machine would
otherwise hit `command not found: starship` on every shell start. Windows
has no unattended path (winget needs an interactive prompt), so it stays a
manual prerequisite (see table above).

`starship/starship.toml` is copied to `~/.config/starship.toml` on both OSes.
Beyond matching the prompt, it raises `scan_timeout` to 120 ms (default 30)
and `command_timeout` to 1000 ms. On Windows the directory scan competes with
Sophos on-access AV, and the Google Drive `Z:` mount is a virtual FAT32
filesystem served by GoogleDriveFS (a user-mode driver, slower than kernel
NTFS), so per-file reads there blew past the 30 ms default and made Starship
log `Scanning current directory timed out`. The higher value absorbs it.

### PowerShell: profile start-up cost

The PS7 profile was reporting `Loading personal and system profiles took
3210ms`. Measured per block, three imports accounted for most of it:
Terminal-Icons ~950ms, `starship init` ~700ms, DockerCompletion ~430ms. Two are
now dealt with, taking the profile itself from ~2810ms to ~1675ms:

- **starship** init is cached to `%LOCALAPPDATA%\starship\init.ps1` and
  dot-sourced, regenerated only when the starship binary is newer than the
  cache. It must be cached with `--print-full-init`: plain `starship init
  powershell` returns a 198-byte bootstrap that re-invokes starship at runtime,
  so caching *that* still spawns the process every start. The cache keys off
  the binary, not `starship.toml`, because the init script embeds no config --
  editing the toml takes effect with no regeneration.
- **Terminal-Icons** is no longer imported eagerly. It only decorates directory
  listings, so the profile's own `ls` function imports it on first call. The
  trade-off: `dir`/`Get-ChildItem` called directly before the first `ls` comes
  out undecorated, and that first `ls` pays the ~950ms.

**DockerCompletion (~430ms) is left as-is on purpose.** It exists to register a
`docker` tab-completer, and a completer has to be registered *before* Tab is
pressed -- there is no hook for "about to complete", so lazy-loading it would
simply remove the feature. It is pay-every-start or drop it.

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
note explains how to push manually. When the base is another feature branch,
`wtnew` prints the resulting stack chain (walking the recorded `wt-parent`
links) and warns that the base is not yet merged — so the new branch's PR will
be stacked on the base's PR and must merge bottom-up, never opened against
`main`.

`wtls` shows one row per worktree with the branch, its fork parent (FROM), the
PR state **and the base that PR opens against** (`#50 OPEN→phase3`), plus the
PR's own diff (commits/additions/deletions). Three stack anomalies are flagged
with a red `⚠`: a PR whose base is not the branch's parent (it is replaying the
parent's commits — with `(propios N)` showing what is actually this branch's
own work), a duplicate branch pointing at the same commit as another, and a
branch with unmerged work but no PR at all. FROM falls back to a
nearest-ancestor autodetect across all local branches when no `wt-parent` is
recorded.

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
`claude/settings.json`'s SessionStart/Stop hooks **and** `codex/hooks.json`'s
SessionStart/Stop hooks — both call the same script) and `engram/sync.ps1`
(Windows, invoked by `claude/settings.windows.json`). `apply-to-system.sh`
copies each script into the existing `~/.engram-sync` clone without touching
its `.git/` or `.engram/` data; `sync-from-system.sh` pulls them back the
same way, skipping the copy on a machine where `~/.engram-sync` hasn't been
cloned yet.

`codex/hooks.json` is handled differently: it's **merged**, not copied, via
`codex/merge-hooks.py`, into `${CODEX_HOME:-~/.codex}/hooks.json` — adding
our SessionStart/Stop entries only if their exact command isn't already
there. A blind copy would be destructive on this machine: Codex CLI here is
wrapped by Orca, which sets `CODEX_HOME` to an Orca-managed runtime directory
(`~/.local/share/orca/codex-runtime-home/home`, **not** `~/.codex`) whose
`hooks.json` already carries Orca's own per-event `codex-hook.sh` dispatcher
for every event — overwriting it would silently break that. `~/.codex/hooks.json`
itself is left with our entries too, as the fallback for a plain
(non-Orca-wrapped) Codex install where `CODEX_HOME` isn't overridden.

Two things learned the hard way while wiring this up, verified with `codex
doctor`, live binary inspection, and repeated `codex exec` test runs (never
against the real hooks — always against a disposable throwaway script first):

- Codex's `SessionEnd` event only fires in the interactive TUI (confirmed:
  never fired under `codex exec` even after fixing the CODEX_HOME
  discovery), and is hard-clamped to a 1s default / 3s max regardless of the
  `timeout` you set — and `async: true` is a documented no-op ("parsed, but
  asynchronous command hooks aren't supported yet"), so it can't be used to
  background a slow push. The push hook is wired to `Stop` instead — it
  fires after every turn in **both** interactive and `codex exec` mode, with
  the same 600s default timeout as other events, so a normal blocking
  `sync.sh push` fits comfortably with no backgrounding trick needed.
- Never test a hook that runs `git` by wrapping it in a hard `timeout N`
  wrapper: a kill mid-rebase leaves `.git/rebase-merge` in a state
  `git rebase --abort` can't always clean up, which then looks like a
  recurring content conflict on every later sync attempt. Test hooks against
  a disposable script first; only point them at the real command once the
  wiring itself is confirmed.
