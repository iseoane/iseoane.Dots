#!/usr/bin/env bash
# Update everything on this machine. Each step runs independently: a failure
# is reported at the end but never stops the remaining steps.
#
# Order: OS -> package managers -> standalone tools -> AI agents & ecosystem.
set -uo pipefail

failed=()

step() {
	local name="$1"; shift
	printf '\n\033[1;36m==> %s\033[0m\n' "$name"
	if "$@"; then
		printf '\033[1;32m✔ %s\033[0m\n' "$name"
	else
		printf '\033[1;31m✘ %s (exit %s)\033[0m\n' "$name" "$?"
		failed+=("$name")
	fi
}

section() { printf '\n\033[1;35m######## %s ########\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. Operating system (Debian) -----------------------------------------
section "1. Debian"
sudo -v || { echo "sudo is required for the OS steps"; exit 1; }
step "APT update"     sudo apt-get update
step "APT upgrade"    sudo apt-get full-upgrade -y --fix-missing
step "APT autoremove" sudo apt-get autoremove --purge -y

# --- 2. npm ----------------------------------------------------------------
# Updates npm itself and generic global packages (opencode, pi runtime...).
# npm >= 11 blocks install scripts unless allowed. Trusted packages are listed
# once in the user npmrc (allow-scripts=gentle-pi,opencode-ai,@google/genai,
# protobufjs,esbuild); without it opencode-ai and gentle-pi end up half-installed.
section "2. npm"
step "npm self-update"     npm install -g npm@latest
step "npm global packages" npm update -g

# --- 3. Homebrew -----------------------------------------------------------
# Only holds gentle-ai; engram and gga are NOT brew-managed (see step 5).
if have brew; then
	section "3. Homebrew"
	step "Homebrew update"  brew update
	step "Homebrew upgrade" brew upgrade
	step "Homebrew cleanup" brew cleanup
fi

# --- 4. Standalone tools ---------------------------------------------------
section "4. Standalone tools"
have uv    && step "uv"       uv self update
have uv    && step "uv tools" uv tool upgrade --all
have pnpm  && step "pnpm"            pnpm self-update
have pnpm  && step "pnpm global pkgs" pnpm update -g
have bun   && step "bun"             bun upgrade
have herdr && step "herdr"           herdr update

# --- 5. AI agents & ecosystem ----------------------------------------------
section "5. AI agents"
# One binary serves both profiles: ~/.claude (gentle-ai) and ~/.claude-vanilla
# (CLAUDE_CONFIG_DIR). gentle-ai sync only touches ~/.claude; vanilla config is
# restored from the dots repo (claude/manage.mjs --profile vanilla).
have claude && step "Claude Code" claude update
have codex  && step "Codex"       codex update

# gentle-ai upgrade also downloads engram and gga into ~/.local/bin.
# sync only touches opencode, claude-code and codex (Pi is not managed).
step "gentle-ai upgrade (+ engram, gga)" gentle-ai upgrade
step "gentle-ai sync"                    gentle-ai sync

# A running `engram serve` keeps the old (deleted) binary after an upgrade.
restart_engram_serve() {
	pgrep -x -f 'engram serve' >/dev/null || return 0
	pkill -x -f 'engram serve' && sleep 1
	(cd ~ && setsid nohup engram serve >/dev/null 2>&1 </dev/null &)
	sleep 1 && pgrep -x -f 'engram serve' >/dev/null
}
step "engram serve restart" restart_engram_serve

have codegraph && step "CodeGraph" codegraph upgrade

# gentle-shell (npm package gentle-pi): @latest also crosses major versions,
# which `npm update -g` does not. Its postinstall is allowed via the npmrc.
step "gentle-shell (gentle-pi)" npm install -g gentle-pi@latest

# Pi stays independent from gentle-shell.
if have pi; then
	step "Pi"            pi update
	step "Pi extensions" pi update --extensions
	step "Pi models"     pi update --models
fi

# --- Summary ---------------------------------------------------------------
section "Versions"
for t in gentle-ai engram gga codegraph gentle-shell pi claude codex herdr; do
	have "$t" || continue
	printf '%-13s ' "$t"
	case "$t" in
		gentle-shell) GENTLE_SHELL_NO_AUTO_SETUP=1 "$t" --version 2>&1 | head -1 ;;
		*) "$t" --version 2>&1 | head -1 ;;
	esac
done

if ((${#failed[@]})); then
	printf '\n\033[1;31mFailed steps:\033[0m\n'
	printf '  - %s\n' "${failed[@]}"
	exit 1
fi
printf '\n\033[1;32mEverything up to date.\033[0m\n'
[ -f /var/run/reboot-required ] && echo "⚠ A reboot is required (WSL: run 'wsl --shutdown' from Windows)."
