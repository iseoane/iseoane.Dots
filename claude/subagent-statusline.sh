#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# subagentStatusLine · Claude Code · Catppuccin Mocha
# Por subagente:  label │ type │ status │ description │ tokens │ %contexto
#   - status coloreado por estado (activo/hecho/error/pendiente)
#   - ventana asumida 200k; si tokenCount la supera, se asume modelo de 1M
#   - % con franjas de la barra: verde <40, amarillo 40–59, naranja 60–79, rojo ≥80
# Salida: una línea JSON por fila -> {"id":"…","content":"…"}
# Requiere: jq
# ─────────────────────────────────────────────────────────────────────────────

input=$(cat)

DESC_MAX=60   # recorte de la descripción (caracteres)

c() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
GREEN=$(c 166 227 161); YELLOW=$(c 249 226 175); PEACH=$(c 250 179 135)
RED=$(c 243 139 168);   SKY=$(c 137 220 235);    OVERLAY0=$(c 108 112 134)
SURFACE2=$(c 88 91 112); TEXT=$(c 205 214 244);  LAVENDER=$(c 180 190 254)
RESET=$'\033[0m'
SEP="${SURFACE2} │ ${RESET}"

echo "$input" | jq -c '.tasks[]?' | while read -r task; do
    id=$(echo "$task"     | jq -r '.id // empty')
    [ -z "$id" ] && continue
    label=$(echo "$task"  | jq -r '.label // .name // "subagent"')
    type=$(echo "$task"   | jq -r '.type // empty')
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

    # ventana: 200k por defecto; si se supera, asumimos modelo de 1M
    WINDOW=200000
    [ "$tokens" -gt "$WINDOW" ] && WINDOW=1000000
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
    content="${content}${SEP}${scol}${status}${RESET}"
    [ -n "$desc" ] && content="${content}${SEP}${OVERLAY0}${desc}${RESET}"
    content="${content}${SEP}${OVERLAY0}${tok} tok${RESET}${SEP}${pcol}${pct}%${RESET}"

    # jq codifica el ESC como \u001b -> JSON válido; Claude Code lo renderiza
    jq -nc --arg id "$id" --arg content "$content" '{id:$id, content:$content}'
done
