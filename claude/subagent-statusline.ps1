# ─────────────────────────────────────────────────────────────────────────────
# subagentStatusLine · Claude Code · Catppuccin Mocha (PowerShell 7+)
# Por subagente:  label | agentType | modelo (esfuerzo) | status | description | tokens | %contexto
#   - status coloreado por estado (activo/hecho/error/pendiente)
#   - ventana real (contextWindowSize); si falta, 200k o 1M si tokenCount la supera
#   - % con franjas de la barra: verde <40, amarillo 40-59, naranja 60-79, rojo >=80
# Salida: una linea JSON por fila -> {"id":"…","content":"…"}
# ─────────────────────────────────────────────────────────────────────────────

param([string]$Theme = $env:STATUSLINE_THEME)

[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
if (-not $raw -or -not $raw.Trim()) { exit 0 }
$json = $raw | ConvertFrom-Json

$DESC_MAX = 60                       # recorte de la descripción (caracteres)
$ELL  = [string][char]0x2026         # …
$VBAR = [string][char]0x2502         # separador │

$ESC = [char]27
function C([int]$r,[int]$g,[int]$b){ "$ESC[38;2;$r;$g;${b}m" }
$GREEN    = C 166 227 161
$YELLOW   = C 249 226 175
$PEACH    = C 250 179 135
$RED      = C 243 139 168
$SKY      = C 137 220 235
$LAVENDER = C 180 190 254
$OVERLAY0 = C 108 112 134
$SURFACE2 = C 88 91 112
$TEXT     = C 205 214 244
$PINK     = C 245 194 231
# ── Paleta alternativa xeo-gta (-Theme xeo-gta o STATUSLINE_THEME), a juego con el tema custom ──
if ($Theme -eq "xeo-gta") {
    $MAUVE = C 185 140 255; $BLUE = C 79 200 240;  $GREEN = C 124 242 154
    $PINK  = C 255 46 154;  $SKY  = C 62 230 224;  $SAPPHIRE = C 79 200 240
    $LAVENDER = C 185 140 255; $YELLOW = C 245 230 99; $PEACH = C 255 138 61
    $RED   = C 255 61 94;   $TEAL = C 62 230 224;  $SURFACE2 = C 58 63 99
    $OVERLAY0 = C 122 127 158; $TEXT = C 79 200 240
}
$RESET    = "$ESC[0m"
$SEP      = "$SURFACE2 $VBAR $RESET"

foreach ($task in $json.tasks) {
    if (-not $task.id) { continue }

    $label = $task.label
    if (-not $label) { $label = $task.name }
    if (-not $label) { $label = "subagent" }

    $type = $task.agentType
    if (-not $type) { $type = $task.type }
    if (-not $type) { $type = "" }

    # modelo legible: claude-sonnet-5-5 -> sonnet 5.5
    $model = $task.model
    if (-not $model) { $model = "" }
    if ($model -match '^claude-([a-z]+)-([0-9]+)-([0-9]+)') { $model = "$($Matches[1]) $($Matches[2]).$($Matches[3])" }
    $effort = $task.effort

    $status = $task.status
    if (-not $status) { $status = "-" }

    $desc = $task.description
    if (-not $desc) { $desc = "" }
    if ($desc.Length -gt $DESC_MAX) { $desc = $desc.Substring(0, $DESC_MAX) + $ELL }

    # color del status por estado (ajusta a los valores reales si difieren)
    switch -Regex ($status) {
        '^(running|in_progress|active|working)$' { $scol = $SKY;      break }
        '^(done|completed|success|finished)$'    { $scol = $GREEN;    break }
        '^(error|failed|cancelled)$'             { $scol = $RED;      break }
        '^(pending|queued|waiting)$'             { $scol = $OVERLAY0; break }
        default                                  { $scol = $TEXT }
    }

    $tokens = $task.tokenCount
    if ($null -eq $tokens) { $tokens = 0 }

    # tokens legibles
    if ($tokens -ge 1000) { $tok = ("{0}k" -f [int]($tokens / 1000)) } else { $tok = "$tokens" }

    # ventana: la real si viene; si no, 200k (o 1M si se supera)
    $WINDOW = 0
    if ($task.contextWindowSize) { $WINDOW = [long]$task.contextWindowSize }
    if ($WINDOW -le 0) { $WINDOW = 200000; if ($tokens -gt $WINDOW) { $WINDOW = 1000000 } }
    $pct = [int]([double]$tokens * 100 / $WINDOW)
    if ($pct -gt 100) { $pct = 100 }
    if     ($pct -lt 40) { $pcol = $GREEN }
    elseif ($pct -lt 60) { $pcol = $YELLOW }
    elseif ($pct -lt 80) { $pcol = $PEACH }
    else                 { $pcol = $RED }

    # montaje (type y description solo si existen)
    $content = "$TEXT$label$RESET"
    if ($type) { $content += "$SEP$LAVENDER$type$RESET" }
    if ($model) {
        $content += "$SEP$PINK$model$RESET"
        if ($effort) { $content += " $SKY($effort)$RESET" }
    }
    $content += "$SEP$scol$status$RESET"
    if ($desc) { $content += "$SEP$OVERLAY0$desc$RESET" }
    $content += "$SEP$OVERLAY0$tok tok$RESET$SEP$pcol${pct}%$RESET"

    # ConvertTo-Json escapa el ESC como \u001b -> JSON válido; Claude lo renderiza
    [pscustomobject]@{ id = $task.id; content = $content } | ConvertTo-Json -Compress
}