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
# zsh-completions adds extra completion definitions; register it before compinit.
[[ -d "$HOME/.zsh/zsh-completions/src" ]] && fpath=("$HOME/.zsh/zsh-completions/src" $fpath)

autoload -Uz compinit
# Docker Desktop's WSL integration mounts /usr/share/zsh/vendor-completions/_docker
# as a symlink only while it's running; filter the resulting dangling-symlink
# warning instead of the whole compinit output, so real errors still surface.
compinit 2> >(grep -v 'vendor-completions/_docker')

zstyle ':completion:*' menu select                       # arrow-key selectable menu
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' # case-insensitive matching
zstyle ':completion:*' list-colors ''                    # colored completion list
setopt COMPLETE_IN_WORD                                   # complete from the cursor position
setopt ALWAYS_TO_END                                     # move cursor to end after completion

# ── Autosuggestions (fish-like inline suggestions from history) ─────
if [[ -r "$HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
  source "$HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh"
elif [[ -r /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
fi
(( $+widgets[autosuggest-accept] )) && bindkey '^ ' autosuggest-accept # Ctrl+Space to accept

# ── Keybindings ─────────────────────────────────────────────────────
bindkey -e                                               # emacs-style keybindings
bindkey '^[[A' history-beginning-search-backward         # Up: search history by prefix
bindkey '^[[B' history-beginning-search-forward          # Down: same, forward

# Bind navigation keys from terminfo, then cover the common CSI/SS3 variants
# emitted by WezTerm, Windows Terminal, Linux consoles and SSH clients.
zmodload zsh/terminfo 2>/dev/null
[[ -n ${terminfo[khome]-} ]] && bindkey "${terminfo[khome]}" beginning-of-line
[[ -n ${terminfo[kend]-}  ]] && bindkey "${terminfo[kend]}" end-of-line
[[ -n ${terminfo[kdch1]-} ]] && bindkey "${terminfo[kdch1]}" delete-char
[[ -n ${terminfo[kpp]-}   ]] && bindkey "${terminfo[kpp]}" history-beginning-search-backward
[[ -n ${terminfo[knp]-}   ]] && bindkey "${terminfo[knp]}" history-beginning-search-forward
for sequence in $'\e[H' $'\e[1~' $'\eOH'; bindkey "$sequence" beginning-of-line
for sequence in $'\e[F' $'\e[4~' $'\eOF'; bindkey "$sequence" end-of-line
bindkey $'\e[3~' delete-char
bindkey $'\e[5~' history-beginning-search-backward
bindkey $'\e[6~' history-beginning-search-forward
unset sequence

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
alias oc='opencode --auto'

# herdr worktree helpers (migrated from .bashrc)
alias lswt='~/.config/herdr/scripts/herdr-wt ls'
alias crwt='~/.config/herdr/scripts/herdr-wt cr'
alias openwt='~/.config/herdr/scripts/herdr-wt open'
alias rmwt='~/.config/herdr/scripts/herdr-wt rm'

# worktree management (herdr-independent, plain git worktree)
[ -f ~/.config/worktree-management/worktree-mgmt.sh ] && source ~/.config/worktree-management/worktree-mgmt.sh

# ── Syntax highlighting ─────────────────────────────────────────────
# Must be sourced LAST, after all other zle widgets are defined.
if [[ -r "$HOME/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
  source "$HOME/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
elif [[ -r /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# System syntax colours. Set after the plugin so these semantic roles win over
# its defaults. Keep this map aligned with PowerShell's PSReadLine colours.
typeset -gA ZSH_HIGHLIGHT_STYLES
# Tokyo Night semantic roles; fuchsia matches the active window border.
ZSH_HIGHLIGHT_STYLES[default]='fg=#A9B1D6'
ZSH_HIGHLIGHT_STYLES[command]='fg=#FF2E9A'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=#FF2E9A'
ZSH_HIGHLIGHT_STYLES[function]='fg=#FF2E9A'
ZSH_HIGHLIGHT_STYLES[alias]='fg=#FF2E9A'
ZSH_HIGHLIGHT_STYLES[suffix-alias]='fg=#FF2E9A'
ZSH_HIGHLIGHT_STYLES[hashed-command]='fg=#FF2E9A'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=#FF2E9A,italic'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=#F7768E'
ZSH_HIGHLIGHT_STYLES[reserved-word]='fg=#AD8EE6'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=#9ECE6A'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=#9ECE6A'
ZSH_HIGHLIGHT_STYLES[dollar-quoted-argument]='fg=#9ECE6A'
ZSH_HIGHLIGHT_STYLES[rc-quote]='fg=#9ECE6A'
ZSH_HIGHLIGHT_STYLES[single-hyphen-option]='fg=#7AA2F7'
ZSH_HIGHLIGHT_STYLES[double-hyphen-option]='fg=#7AA2F7'
ZSH_HIGHLIGHT_STYLES[path]='fg=#A9B1D6'
ZSH_HIGHLIGHT_STYLES[globbing]='fg=#449DAB'
ZSH_HIGHLIGHT_STYLES[commandseparator]='fg=#449DAB'
ZSH_HIGHLIGHT_STYLES[redirection]='fg=#A9B1D6'
ZSH_HIGHLIGHT_STYLES[comment]='fg=#414868'
ZSH_HIGHLIGHT_STYLES[dollar-double-quoted-argument]='fg=#BB9AF7'
ZSH_HIGHLIGHT_STYLES[back-double-quoted-argument]='fg=#AD8EE6'
ZSH_HIGHLIGHT_STYLES[assign]='fg=#BB9AF7'
ZSH_HIGHLIGHT_STYLES[named-fd]='fg=#B9F27C'
ZSH_HIGHLIGHT_STYLES[numeric-fd]='fg=#B9F27C'
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#414868'

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

export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# >>> Codex installer >>>
export PATH="/home/iseoane/.local/bin:$PATH"
# <<< Codex installer <<<
