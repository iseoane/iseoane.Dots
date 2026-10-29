#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# subagentStatusLine · Claude Code · Catppuccin Mocha
# Por subagente:  label │ agentType │ modelo (esfuerzo) │ status │ description │ tokens │ %contexto
#   - status coloreado por estado (activo/hecho/error/pendiente)
#   - ventana real (contextWindowSize); si falta, 200k o 1M si tokenCount la supera
#   - % con franjas de la barra: verde <40, amarillo 40–59, naranja 60–79, rojo ≥80
# Salida: una línea JSON por fila -> {"id":"…","content":"…"}
# Requiere: jq
# ─────────────────────────────────────────────────────────────────────────────

input=$(cat)

DESC_MAX=60   # recorte de la descripción (caracteres)

c() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
GREEN=$(c 166 227 161); YELLOW=$(c 249 226 175); PEACH=$(c 250 179 135)
RED=$(c 243 139 168);   SKY=$(c 137 220 235);    OVERLAY0=$(c 108 112 134)
PINK=$(c 245 194 231)
SURFACE2=$(c 88 91 112); TEXT=$(c 205 214 244);  LAVENDER=$(c 180 190 254)
# ── Paleta alternativa xeo-gta (STATUSLINE_THEME=xeo-gta), a juego con el tema custom ──
if [ "${STATUSLINE_THEME:-}" = "xeo-gta" ]; then
    MAUVE=$(c 185 140 255); BLUE=$(c 79 200 240);   GREEN=$(c 124 242 154)
    PINK=$(c 255 46 154);   SKY=$(c 62 230 224);    SAPPHIRE=$(c 79 200 240)
    LAVENDER=$(c 185 140 255); YELLOW=$(c 245 230 99); PEACH=$(c 255 138 61)
    RED=$(c 255 61 94);     TEAL=$(c 62 230 224);   SURFACE2=$(c 58 63 99)
    OVERLAY0=$(c 122 127 158); TEXT=$(c 79 200 240)
fi
RESET=$'\033[0m'
SEP="${SURFACE2} │ ${RESET}"

echo "$input" | jq -c '.tasks[]?' | while read -r task; do
    id=$(echo "$task"     | jq -r '.id // empty')
    [ -z "$id" ] && continue
    label=$(echo "$task"  | jq -r '.label // .name // "subagent"')
    type=$(echo "$task"   | jq -r '.agentType // .type // empty')
    model=$(echo "$task"  | jq -r '.model // empty')
    effort=$(echo "$task" | jq -r '.effort // empty')
    window=$(echo "$task" | jq -r '.contextWindowSize // empty')
    status=$(echo "$task" | jq -r '.status // "-"')
    desc=$(echo "$task"   | jq -r '.description // empty')
    tokens=$(echo "$task" | jq -r '.tokenCount // 0')

    # color del status por estado (ajusta a los valores reales si difieren)
    case "$status" in
        running|in_progress|active|working) scol=$SKY ;;
        done|completed|success|finished)    scol=$GREEN ;;
        error|failed|cancelled)             scol=$RED ;;
        pending|queued|waiting)             scol=$OVERLAY0 ;;
        *)                                  scol=$TEXT ;;
    esac

    # descripción recortada
    [ -n "$desc" ] && [ "${#desc}" -gt "$DESC_MAX" ] && desc="${desc:0:$DESC_MAX}…"

    # tokens legibles
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0
    if [ "$tokens" -ge 1000 ]; then tok="$(( tokens / 1000 ))k"; else tok="$tokens"; fi

    # modelo legible: claude-sonnet-5-5 -> sonnet 5.5
    if [[ "$model" =~ ^claude-([a-z]+)-([0-9]+)-([0-9]+) ]]; then
        model="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    fi

    # ventana: la real si viene; si no, 200k (o 1M si se supera)
    if [[ "$window" =~ ^[0-9]+$ ]] && [ "$window" -gt 0 ]; then WINDOW=$window
    else WINDOW=200000; [ "$tokens" -gt "$WINDOW" ] && WINDOW=1000000
    fi
    pct=$(( tokens * 100 / WINDOW ))
    [ "$pct" -gt 100 ] && pct=100
    if   [ "$pct" -lt 40 ]; then pcol=$GREEN
    elif [ "$pct" -lt 60 ]; then pcol=$YELLOW
    elif [ "$pct" -lt 80 ]; then pcol=$PEACH
    else                         pcol=$RED
    fi

    # montaje (type y description solo si existen)
    content="${TEXT}${label}${RESET}"
    [ -n "$type" ] && content="${content}${SEP}${LAVENDER}${type}${RESET}"
    if [ -n "$model" ]; then
        content="${content}${SEP}${PINK}${model}${RESET}"
        [ -n "$effort" ] && content="${content} ${SKY}(${effort})${RESET}"
    fi
    content="${content}${SEP}${scol}${status}${RESET}"
    [ -n "$desc" ] && content="${content}${SEP}${OVERLAY0}${desc}${RESET}"
    content="${content}${SEP}${OVERLAY0}${tok} tok${RESET}${SEP}${pcol}${pct}%${RESET}"

    # jq codifica el ESC como \u001b -> JSON válido; Claude Code lo renderiza
    jq -nc --arg id "$id" --arg content "$content" '{id:$id, content:$content}'
done
