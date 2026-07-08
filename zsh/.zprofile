# ~/.zprofile — login shell config (environment, runs once per session)
# Read by login shells BEFORE ~/.zshrc. Put here anything that should be set
# once and INHERITED by child shells: environment variables and PATH.
# Interactive-only config (prompt, aliases, completion) lives in ~/.zshrc.

# ── PATH ────────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.npm-global/bin:$PATH"

# ── Java ────────────────────────────────────────────────────────────
# NOTE: fixed from the old .bashrc, which added $JAVA_HOME (not its bin/) to
# PATH, so `java`/`javac` were never on PATH. Executables live in $JAVA_HOME/bin.
export JAVA_HOME="/usr/lib/jvm/jdk1.8.0_301"
export JRE_HOME="$JAVA_HOME/jre"
export PATH="$JAVA_HOME/bin:$PATH"

export CODIGOFUENTE=/mnt/c/0-BackupVF/0.SVN/Codigo_Fuente

# ── pnpm ────────────────────────────────────────────────────────────
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac

# ── Homebrew ────────────────────────────────────────────────────────
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# ── bun ─────────────────────────────────────────────────────────────
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
