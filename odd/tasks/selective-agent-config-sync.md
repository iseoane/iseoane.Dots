# Selective agent config sync

## Objective
Version only user-owned configuration for Claude (gentle-ai `~/.claude` and vanilla `~/.claude-vanilla`), Pi (`~/.pi/agent`) and gentle-shell (`~/.gentle-shell/agent`). Tool-installed assets (agents, commands, skills, gentle-ai hooks, gentle-shell extensions/npm) stay out.

## Scope
- Claude gentle: user rules block of CLAUDE.md, allowlisted settings keys, user hooks (engram sync, herdr, codegraph), `hooks/herdr-agent-state.sh`, statuslines, output styles with `meta.owner: iseoane`.
- Claude vanilla: full CLAUDE.md, allowlisted settings keys + user hooks, owned output styles.
- Pi: unchanged (`pi/manage.mjs` already selective).
- gentle-shell: allowlisted `settings.json` keys only (no extensions, npm, auth, models-store).
- Remove `claude/agents`, `claude/commands`, `claude/skills` from the repo.

## Tasks
- [x] T0 System prep (inline): gitnexus removed from this node; `owner: iseoane` added to CCA/ELI5/srOPUS; copied to vanilla.
- [x] T1 Claude manager script + sync/apply wiring (delegated writer). Commit b5baa61.
- [x] T2 gentle-shell manager + sync/apply wiring (delegated writer). Commit 9d4ebaa.
- [x] T3 README update and repo snapshot from system (snapshot taken in T1/T2 via real sync). Commit d6f9da5.

## Checks
- `node <manager> check` returns ok for each target; `git diff --stat` shows no agents/commands/skills.
- Applying to a temp target reproduces merged settings without dropping gentle-ai-owned keys.

## Progress
Route: T1–T3 delegated (2+ non-trivial files).

## Verification evidence
- `node claude/manage.mjs check --profile gentle|vanilla`: ok.
- `node gentle-shell/manage.mjs check`, `node pi/manage.mjs check`: ok.
- `node --test claude/manage.test.mjs`: 4 pass.
- `bash -n scripts/*.sh`: ok.
- Apply to scratch copies of ~/.claude, ~/.claude-vanilla and ~/.gentle-shell/agent produced settings.json and CLAUDE.md identical to live (gentle-ai hooks, enabledPlugins preserved).
- Live edit: dots:user-rules markers added around the attribution section in ~/.claude/CLAUDE.md.

## Next step
Review and push the branch; open PR when ready.
