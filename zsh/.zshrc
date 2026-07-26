# ~/.zshrc — lightweight setup, no framework
# Managed by hand: every line is intentional. Plugins live in ~/.zsh

# ── History ─────────────────────────────────────────────────────────
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY          # share history across sessions
setopt HIST_IGNORE_ALL_DUPS   # drop older duplicate entries
setopt HIST_IGNORE_SPACE      # don't record commands starting with a space
setopt HIST_VERIFY            # expand history but let you edit before running

# ── Directory navigation ────────────────────────────────────────────
setopt AUTO_CD                # type a dir name to cd into it
setopt AUTO_PUSHD             # cd pushes onto the dir stack
setopt PUSHD_IGNORE_DUPS

# ── Completion ──────────────────────────────────────────────────────
# zsh-completions adds extra completion definitions; register it before compinit
fpath=(~/.zsh/zsh-completions/src $fpath)

autoload -Uz compinit
compinit

zstyle ':completion:*' menu select                       # arrow-key selectable menu
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' # case-insensitive matching
zstyle ':completion:*' list-colors ''                    # colored completion list
setopt COMPLETE_IN_WORD                                   # complete from the cursor position
setopt ALWAYS_TO_END                                     # move cursor to end after completion

# ── Autosuggestions (fish-like inline suggestions from history) ─────
source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
bindkey '^ ' autosuggest-accept                          # Ctrl+Space to accept a suggestion

# ── Keybindings ─────────────────────────────────────────────────────
bindkey -e                                               # emacs-style keybindings
bindkey '^[[A' history-beginning-search-backward         # Up: search history by prefix
bindkey '^[[B' history-beginning-search-forward          # Down: same, forward

# ── Prompt ──────────────────────────────────────────────────────────
# Now managed by Starship (see init below). The manual vcs_info prompt is
# kept commented as a fallback — remove the Starship init line to restore it.
# autoload -Uz vcs_info
# zstyle ':vcs_info:git:*' formats ' %F{yellow}(%b)%f'
# precmd() { vcs_info }
# setopt PROMPT_SUBST
# PROMPT='%F{cyan}%n@%m%f %F{green}%~%f${vcs_info_msg_0_} %# '
eval "$(starship init zsh)"

# ── Environment / PATH ──────────────────────────────────────────────
# Moved to ~/.zprofile: environment variables and PATH belong in the login
# shell so they are set once and inherited by all child shells.

# ── Functions (migrated from .bashrc) ───────────────────────────────
dcdev() {
  docker compose --env-file .env.development "$@"
}

# ── Aliases ─────────────────────────────────────────────────────────
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'

# herdr worktree helpers (migrated from .bashrc)
alias lswt='~/.config/herdr/scripts/herdr-wt ls'
alias crwt='~/.config/herdr/scripts/herdr-wt cr'
alias openwt='~/.config/herdr/scripts/herdr-wt open'
alias rmwt='~/.config/herdr/scripts/herdr-wt rm'

# worktree management (herdr-independent, plain git worktree)
[ -f ~/.config/worktree-management/worktree-mgmt.sh ] && source ~/.config/worktree-management/worktree-mgmt.sh

# ── Syntax highlighting ─────────────────────────────────────────────
# Must be sourced LAST, after all other zle widgets are defined
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# ── Auto-launch herdr on interactive shells (migrated from .bashrc) ─
# Guards:
#   $- == *i*      -> only interactive shells (not scripts)
#   -z $HERDR_ENV  -> not already inside herdr (herdr sets HERDR_ENV=1) -> avoids loop
#   -z $NO_HERDR   -> escape hatch: run `NO_HERDR=1 zsh` to get a plain shell
# DISABLED 2026-07-05: auto-launch paused while trying Starship solo. Launch herdr
# manually with `herdr`. To restore auto-launch, uncomment the block below.
# if [[ $- == *i* ]] && [[ -z "$HERDR_ENV" ]] && [[ -z "$NO_HERDR" ]] && command -v herdr >/dev/null 2>&1; then
#     exec herdr
# fi
