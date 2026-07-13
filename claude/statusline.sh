#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Statusline Claude Code · Catppuccin Mocha · 2 líneas
# L1: usuario │ dir (rama git) │ modelo (esfuerzo)
# L2: barra ctx % │ 5h ↻reset │ 7d
# Requiere: jq · git
# ─────────────────────────────────────────────────────────────────────────────

input=$(cat)

# ── Paleta Catppuccin Mocha (truecolor 24-bit) ──────────────────────────────
c() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
MAUVE=$(c 203 166 247)      # usuario
BLUE=$(c 137 180 250)       # directorio
GREEN=$(c 166 227 161)      # rama git / barra verde
PINK=$(c 245 194 231)       # modelo
SKY=$(c 137 220 235)        # esfuerzo
SAPPHIRE=$(c 116 199 236)   # ventana 5h
LAVENDER=$(c 180 190 254)   # ventana 7d
YELLOW=$(c 249 226 175)     # barra amarilla
PEACH=$(c 250 179 135)      # barra naranja
RED=$(c 243 139 168)        # barra roja
TEAL=$(c 148 226 213)       # PR
SURFACE2=$(c 88 91 112)     # bloques vacíos / separadores
OVERLAY0=$(c 108 112 134)   # texto tenue (paréntesis, hora reset)
RESET=$'\033[0m'
SEP="${SURFACE2} │ ${RESET}"

# Enlace OSC 8 (clicable en terminales compatibles); texto plano si no hay URL
ESC=$'\033'; LST="${ESC}\\"
link() {  # $1=texto  $2=url
    if [ -n "$2" ]; then printf '%s]8;;%s%s%s%s]8;;%s' "$ESC" "$2" "$LST" "$1" "$ESC" "$LST"
    else printf '%s' "$1"; fi
}

# ── Usuario (NO viene en el JSON: se toma del shell) ────────────────────────
USER_NAME="${USER:-$(whoami)}"

# ── Directorio + rama git + URL del repo ────────────────────────────────────
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
PROJ="${DIR##*/}"

RHOST=$(echo "$input"  | jq -r '.workspace.repo.host // empty')
ROWNER=$(echo "$input" | jq -r '.workspace.repo.owner // empty')
RNAME=$(echo "$input"  | jq -r '.workspace.repo.name // empty')
REPO_URL=""
[ -n "$RHOST" ] && [ -n "$ROWNER" ] && [ -n "$RNAME" ] && REPO_URL="https://${RHOST}/${ROWNER}/${RNAME}"
PROJ_DISP=$(link "$PROJ" "$REPO_URL")   # nombre de proyecto como enlace al repo

BRANCH=""
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    B=$(git -C "$DIR" branch --show-current 2>/dev/null)
    [ -n "$B" ] && BRANCH=" ${OVERLAY0}(${GREEN}${B}${OVERLAY0})${RESET}"
fi

# ── Modelo + esfuerzo ───────────────────────────────────────────────────────
MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')
EFFORT=$(echo "$input" | jq -r '.effort.level // empty')
EFFORT_STR=""
[ -n "$EFFORT" ] && EFFORT_STR=" ${SKY}(${EFFORT})${RESET}"

# ── Barra de contexto (1 bloque = 5%, 20 bloques) ───────────────────────────
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
if   [ "$PCT" -lt 40 ]; then BAR_COLOR="$GREEN"   # 0–39   verde
elif [ "$PCT" -lt 60 ]; then BAR_COLOR="$YELLOW"  # 40–59  amarillo
elif [ "$PCT" -lt 80 ]; then BAR_COLOR="$PEACH"   # 60–79  naranja
else                         BAR_COLOR="$RED"     # 80–100 rojo
fi
WIDTH=20
FILLED=$((PCT / 5)); [ "$FILLED" -gt "$WIDTH" ] && FILLED=$WIDTH
EMPTY=$((WIDTH - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && printf -v F "%${FILLED}s" && BAR="${F// /█}"
[ "$EMPTY"  -gt 0 ] && printf -v E "%${EMPTY}s"  && BAR="${BAR}${SURFACE2}${E// /░}"
CTX="${BAR_COLOR}${BAR}${RESET} ${BAR_COLOR}${PCT}%${RESET}"

# ── Límites de uso (solo Claude.ai Pro/Max, tras la 1ª respuesta) ───────────
fmt_epoch() {  # $1=epoch  $2=formato strftime  (GNU date o BSD date)
    [ -z "$1" ] && return
    date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null
}
H5=$(echo "$input"       | jq -r '.rate_limits.five_hour.used_percentage // empty')
H5_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
D7=$(echo "$input"       | jq -r '.rate_limits.seven_day.used_percentage // empty')
D7_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

FIVE_STR=""
if [ -n "$H5" ]; then
    FIVE_STR="${SAPPHIRE}5h ${H5%.*}%${RESET}"
    R=$(fmt_epoch "$H5_RESET" "%H:%M")        # mismo día → solo hora
    [ -n "$R" ] && FIVE_STR="${FIVE_STR} ${OVERLAY0}↻${R}${RESET}"
fi
SEVEN_STR=""
if [ -n "$D7" ]; then
    SEVEN_STR="${LAVENDER}7d ${D7%.*}%${RESET}"
    RD=$(fmt_epoch "$D7_RESET" "%a %H:%M")     # días vista → día + hora
    [ -n "$RD" ] && SEVEN_STR="${SEVEN_STR} ${OVERLAY0}↻${RD}${RESET}"
fi

# ── Líneas editadas en la sesión (cost.total_lines_added / removed) ─────────
ADDED=$(echo "$input"   | jq -r '.cost.total_lines_added // 0')
REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
[[ "$ADDED"   =~ ^[0-9]+$ ]] || ADDED=0
[[ "$REMOVED" =~ ^[0-9]+$ ]] || REMOVED=0
DIFF_STR=""
if [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ]; then
    DIFF_STR="${GREEN}+${ADDED}${RESET} ${RED}-${REMOVED}${RESET}"
fi

# ── PR abierto de la rama (mirror del badge del footer) ─────────────────────
PR_NUM=$(echo "$input" | jq -r '.pr.number // empty')
PR_URL=$(echo "$input" | jq -r '.pr.url // empty')
PR_STR=""
[ -n "$PR_NUM" ] && PR_STR="${TEAL}$(link "PR: #${PR_NUM}" "$PR_URL")${RESET}"

# ── Montaje (2 líneas) ──────────────────────────────────────────────────────
# Línea 1 (identidad):  usuario │ dir (rama) │ modelo (esfuerzo) [│ PR: #n]
# Línea 2 (métricas):   barra ctx % │ +añadidas -eliminadas │ 5h ↻reset │ 7d
LINE1="${MAUVE}${USER_NAME}${RESET}${SEP}${BLUE}${PROJ_DISP}${RESET}${BRANCH}${SEP}${PINK}${MODEL}${RESET}${EFFORT_STR}"
[ -n "$PR_STR" ] && LINE1="${LINE1}${SEP}${PR_STR}"
LINE2="${CTX}"
[ -n "$DIFF_STR" ]  && LINE2="${LINE2}${SEP}${DIFF_STR}"
[ -n "$FIVE_STR" ]  && LINE2="${LINE2}${SEP}${FIVE_STR}"
[ -n "$SEVEN_STR" ] && LINE2="${LINE2}${SEP}${SEVEN_STR}"

printf '%s\n' "$LINE1"
printf '%s\n' "$LINE2"
