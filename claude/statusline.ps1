# ─────────────────────────────────────────────────────────────────────────────
# Statusline Claude Code · Catppuccin Mocha · 2 lineas (PowerShell 5.1 / 7+)
# L1: usuario | dir (rama git) | modelo (esfuerzo)
# L2: barra ctx % | 5h reset | 7d
# Requiere: git en el PATH
# ─────────────────────────────────────────────────────────────────────────────

[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
if (-not $raw -or -not $raw.Trim()) { exit 0 }
$json = $raw | ConvertFrom-Json

# ── Glifos por codigo (evita problemas de encoding del .ps1) ────────────────
$BLK   = [string][char]0x2588   # bloque lleno
$LITE  = [string][char]0x2591   # bloque vacio
$VBAR  = [string][char]0x2502   # separador │
$REC   = [string][char]0x21BB   # icono reset ↻
$LST   = "$([char]27)\"         # String Terminator OSC 8 (ESC \)

# ── Paleta Catppuccin Mocha (truecolor) ─────────────────────────────────────
$ESC = [char]27
function C([int]$r,[int]$g,[int]$b){ "$ESC[38;2;$r;$g;${b}m" }
$MAUVE    = C 203 166 247
$BLUE     = C 137 180 250
$GREEN    = C 166 227 161
$PINK     = C 245 194 231
$SKY      = C 137 220 235
$SAPPHIRE = C 116 199 236
$LAVENDER = C 180 190 254
$YELLOW   = C 249 226 175
$PEACH    = C 250 179 135
$RED      = C 243 139 168
$TEAL     = C 148 226 213
$SURFACE2 = C 88 91 112
$OVERLAY0 = C 108 112 134
$RESET    = "$ESC[0m"
$SEP      = "$SURFACE2 $VBAR $RESET"

# Enlace OSC 8 (clicable en terminales compatibles); texto plano si no hay URL
function Link($text, $url) {
    if ($url) { "$ESC]8;;$url$LST$text$ESC]8;;$LST" } else { "$text" }
}

# ── Usuario (no viene en el JSON) ───────────────────────────────────────────
$user = $env:USERNAME
if (-not $user) { $user = $env:USER }

# ── Directorio + rama git + URL del repo ────────────────────────────────────
$dir = $json.workspace.current_dir
if (-not $dir) { $dir = $json.cwd }
$proj = if ($dir) { Split-Path $dir -Leaf } else { "" }

$repoUrl = ""
$rhost  = $json.workspace.repo.host
$rowner = $json.workspace.repo.owner
$rname  = $json.workspace.repo.name
if ($rhost -and $rowner -and $rname) { $repoUrl = "https://$rhost/$rowner/$rname" }
$projDisp = Link $proj $repoUrl     # nombre de proyecto como enlace al repo

$branch = ""
if ($dir) {
    git -C "$dir" rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $b = (git -C "$dir" branch --show-current 2>$null)
        if ($b) { $branch = " $OVERLAY0(" + $GREEN + $b + $OVERLAY0 + ")$RESET" }
    }
}

# ── Modelo + esfuerzo ───────────────────────────────────────────────────────
$model = $json.model.display_name
if (-not $model) { $model = "Claude" }
$effortStr = ""
$effort = $json.effort.level
if ($effort) { $effortStr = " $SKY($effort)$RESET" }

# ── Barra de contexto (1 bloque = 5%, 20 bloques) ───────────────────────────
$pct = $json.context_window.used_percentage
if ($null -eq $pct) { $pct = 0 }
$pct = [int][math]::Floor([double]$pct)
if     ($pct -lt 40) { $barColor = $GREEN }
elseif ($pct -lt 60) { $barColor = $YELLOW }
elseif ($pct -lt 80) { $barColor = $PEACH }
else                 { $barColor = $RED }
$width  = 20
$filled = [int][math]::Floor($pct / 5)
if ($filled -gt $width) { $filled = $width }
$empty  = $width - $filled
$bar = $barColor + ($BLK * $filled) + $SURFACE2 + ($LITE * $empty) + $RESET
$ctx = "$bar $barColor$pct%$RESET"

# ── Limites de uso (solo Pro/Max, tras la 1a respuesta) ─────────────────────
$five = ""
$h5 = $json.rate_limits.five_hour.used_percentage
if ($null -ne $h5) {
    $five = $SAPPHIRE + "5h " + [int][math]::Round($h5) + "%" + $RESET
    $ts = $json.rate_limits.five_hour.resets_at
    if ($ts) {
        $rt = [DateTimeOffset]::FromUnixTimeSeconds([long]$ts).LocalDateTime.ToString("HH:mm")
        $five += " " + $OVERLAY0 + $REC + $rt + $RESET
    }
}
$seven = ""
$d7 = $json.rate_limits.seven_day.used_percentage
if ($null -ne $d7) {
    $seven = $LAVENDER + "7d " + [int][math]::Round($d7) + "%" + $RESET
    $ts7 = $json.rate_limits.seven_day.resets_at
    if ($ts7) {
        $rt7 = [DateTimeOffset]::FromUnixTimeSeconds([long]$ts7).LocalDateTime.ToString("ddd HH:mm")
        $seven += " " + $OVERLAY0 + $REC + $rt7 + $RESET
    }
}

# ── Líneas editadas en la sesión (cost.total_lines_added / removed) ─────────
$added = $json.cost.total_lines_added
$removed = $json.cost.total_lines_removed
if ($null -eq $added)   { $added = 0 }
if ($null -eq $removed) { $removed = 0 }
$diff = ""
if ($added -gt 0 -or $removed -gt 0) {
    $diff = "$GREEN+$added$RESET $RED-$removed$RESET"
}

# ── PR abierto de la rama (mirror del badge del footer) ─────────────────────
$prStr = ""
$prNum = $json.pr.number
if ($prNum) {
    $prUrl = $json.pr.url
    $prStr = $TEAL + (Link "PR: #$prNum" $prUrl) + $RESET
}

# ── Montaje (2 lineas) ──────────────────────────────────────────────────────
$line1 = $MAUVE + $user + $RESET + $SEP + $BLUE + $projDisp + $RESET + $branch + $SEP + $PINK + $model + $RESET + $effortStr
if ($prStr) { $line1 += $SEP + $prStr }
$line2 = $ctx
if ($diff)  { $line2 += $SEP + $diff }
if ($five)  { $line2 += $SEP + $five }
if ($seven) { $line2 += $SEP + $seven }

Write-Output $line1
Write-Output $line2