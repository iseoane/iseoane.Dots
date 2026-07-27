#!/usr/bin/env pwsh
# Engram sync (PowerShell 7) — sincroniza el "cerebro" Engram entre máquinas vía repo git privado.
# Usa el git-sync nativo de Engram (chunks append-only), NO la base de datos en crudo.
# Uso:  pwsh -NoProfile -File sync.ps1 pull   (SessionStart)
#       pwsh -NoProfile -File sync.ps1 push   (Stop / SessionEnd)

param(
  [Parameter(Position = 0)]
  [ValidateSet('pull', 'push')]
  [string]$Cmd
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false   # git exit codes != 0 no lanzan excepción

# ── Configuración ────────────────────────────────────────────────────────────
function Get-EnvOr([string]$Name, [string]$Default) {
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrEmpty($v)) { $Default } else { $v }
}

$RepoDir    = Get-EnvOr 'ENGRAM_SYNC_DIR' (Join-Path $HOME '.engram-sync')
$Branch     = Get-EnvOr 'ENGRAM_BRANCH'   'main'
$EngramBin  = Get-EnvOr 'ENGRAM_BIN'      'engram'    # ruta absoluta si no está en el PATH del hook
$LockFile   = Get-EnvOr 'ENGRAM_LOCK'     (Join-Path $HOME '.engram-sync\.sync.lock')
$LogFile    = Get-EnvOr 'ENGRAM_LOG'      (Join-Path $HOME '.engram\sync.log')
$MaxRetries = [int](Get-EnvOr 'ENGRAM_PUSH_RETRIES' '3')
$LogRetentionDays = [int](Get-EnvOr 'ENGRAM_LOG_RETENTION_DAYS' '30')
$HostTag    = try { hostname } catch { 'desconocido' }
$script:Lock = $null

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Log([string]$Msg) {
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $HostTag, $Msg
  Add-Content -Path $LogFile -Value $line
}

# Poda el log a los últimos N días. Las líneas empiezan por 'yyyy-MM-dd ', que
# ordena lexicográficamente = cronológicamente. Sustituye la vieja rotación por
# tamaño (que dejaba crecer un .1 de 1 MB); las líneas sin fecha se conservan.
function Prune-Log {
  if (-not (Test-Path $LogFile)) { return }
  $cutoff = (Get-Date).AddDays(-$LogRetentionDays).ToString('yyyy-MM-dd')
  $kept = foreach ($l in (Get-Content -Path $LogFile)) {
    if ($l -match '^\d{4}-\d{2}-\d{2} ') {
      if ($l.Substring(0, 10) -ge $cutoff) { $l }
    }
    else { $l }
  }
  Set-Content -Path $LogFile -Value $kept
}

# Registra el problema pero NUNCA rompe la sesión de Claude Code (sale con 0).
function Die-Soft([string]$Msg) {
  Write-Log "WARN: $Msg"
  if ($script:Lock) { $script:Lock.Dispose() }
  exit 0
}

function Ensure-Repo {
  $bin = Get-Command $EngramBin -ErrorAction SilentlyContinue
  if (-not $bin) { Die-Soft "binario engram no encontrado en el PATH del hook" }
  if (-not (Test-Path $RepoDir)) { Die-Soft "repo no encontrado: $RepoDir" }
  Set-Location $RepoDir
  & git rev-parse --is-inside-work-tree 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Die-Soft "no es un repo git: $RepoDir" }
}

function Commit-IfChanges {
  & git add -A
  & git diff --cached --quiet
  if ($LASTEXITCODE -eq 0) {
    Write-Log 'Sin chunks nuevos que commitear.'
  }
  else {
    $msg = 'engram sync desde {0} @ {1}' -f $HostTag, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    & git commit -q -m $msg
    if ($LASTEXITCODE -eq 0) { Write-Log 'Chunks nuevos commiteados.' }
    else { Die-Soft 'el commit falló' }
  }
}

# El git-sync comparte observaciones/sesiones/prompts (el contenido real de
# memoria) pero NO el grafo de relaciones de Engram: una mutación de relación
# puede apuntar a una observación que Engram nunca exporta a chunks, y su
# precondición de FK rompe 'engram sync --import' en la otra máquina. Las
# relaciones son metadatos advisory que cada máquina regenera sola, así que las
# quitamos de los chunks recién exportados antes de commitear. Reutiliza el
# mismo prune en Python que sync.sh (Windows también trae python en PATH);
# idempotente: solo reescribe chunks que aún contienen relaciones.
function Strip-Relations {
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
  if (-not $py) { Write-Log 'WARN: python ausente; guard de relaciones omitido'; return }
  $env:ENGRAM_CHUNKS_DIR = Join-Path $RepoDir '.engram\chunks'
  $code = @'
import gzip, json, glob, os
chunks_dir = os.environ["ENGRAM_CHUNKS_DIR"]
for path in glob.glob(os.path.join(chunks_dir, "*.jsonl.gz")):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        raw = f.read()
    had_nl = raw.endswith("\n")
    try:
        data = json.loads(raw.rstrip("\n"))
    except Exception:
        continue
    muts = data.get("mutations") or []
    kept = [m for m in muts if m.get("entity") != "relation"]
    if len(kept) != len(muts):
        data["mutations"] = kept
        out = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
        if had_nl:
            out += "\n"
        with open(path, "wb") as rf:
            with gzip.GzipFile(fileobj=rf, mode="wb", mtime=0) as gz:
                gz.write(out.encode("utf-8"))
'@
  $code | & $py.Source - 2>$null
  if ($LASTEXITCODE -ne 0) { Write-Log 'WARN: guard de relaciones fallo' }
}

function Rebase-Remote {
  # `*>$null` on BOTH git calls, not just stderr: any unredirected output from
  # a native command inside a PowerShell function becomes part of that
  # function's RETURN VALUE alongside the explicit `return`. On a real
  # conflict, `git pull --rebase` prints several lines ("Auto-merging...",
  # "CONFLICT (content)...", hint text) which turned `Rebase-Remote`'s return
  # into a multi-element array -- and a non-empty array is ALWAYS truthy in
  # PowerShell, no matter what its last element is. So `if (-not
  # (Rebase-Remote))` never fired on a genuine conflict: it silently treated
  # every failed rebase as success and let the caller push into a still-broken
  # repo. Confirmed live: a real conflict left `$r` holding conflict text plus
  # `$false`, and `-not $r` still evaluated to `$false`. Suppressing all
  # output makes the function's only output the literal boolean.
  & git -c http.version=HTTP/1.1 pull --rebase --autostash -q origin $Branch *>$null
  if ($LASTEXITCODE -ne 0) {
    & git rebase --abort *>$null
    return $false
  }
  return $true
}

# ── Acciones ──────────────────────────────────────────────────────────────────
function Do-Pull {
  Ensure-Repo
  if (-not (Rebase-Remote)) { Die-Soft 'git pull --rebase falló/conflicto en pull' }
  & $EngramBin sync --import 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Log 'Import OK.' }
  else { Write-Log 'WARN: engram sync --import devolvió error' }
  Write-Log 'Pull OK.'
}

function Do-Push {
  Ensure-Repo
  & $EngramBin sync --all 2>$null
  if ($LASTEXITCODE -ne 0) { Write-Log 'WARN: engram sync --all devolvió error' }
  # Quita el grafo de relaciones de los chunks recién exportados (ver arriba).
  Strip-Relations
  Commit-IfChanges
  for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    if (-not (Rebase-Remote)) {
      Die-Soft "git pull --rebase falló/conflicto (intento $attempt); commit local guardado para el próximo sync"
    }
    # Importa lo que haya traído el rebase de la otra máquina (idempotente)
    & $EngramBin sync --import 2>$null | Out-Null
    & git -c http.version=HTTP/1.1 push -q origin $Branch
    if ($LASTEXITCODE -eq 0) { Write-Log "Push OK (intento $attempt)."; return }
    Write-Log "Push rechazado (intento $attempt) — reintento tras rebase."
  }
  Die-Soft "el push falló tras $MaxRetries intentos"
}

# ── Lock + dispatch ───────────────────────────────────────────────────────────
if (-not $Cmd) { Write-Error 'uso: sync.ps1 {pull|push}'; exit 2 }

New-Item -ItemType Directory -Force -Path (Split-Path $LockFile) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $LogFile)  | Out-Null
Prune-Log

$deadline = (Get-Date).AddSeconds(20)
while ($true) {
  try {
    $script:Lock = [System.IO.File]::Open(
      $LockFile,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None)
    break
  }
  catch {
    if ((Get-Date) -ge $deadline) { Write-Log "Sync ocupado >20s, omito ($Cmd)."; exit 0 }
    Start-Sleep -Milliseconds 500
  }
}

try {
  switch ($Cmd) {
    'pull' { Do-Pull }
    'push' { Do-Push }
  }
}
finally {
  if ($script:Lock) { $script:Lock.Dispose() }
}
