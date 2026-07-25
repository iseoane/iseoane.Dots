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
$LogMaxBytes = 1MB
$HostTag    = try { hostname } catch { 'desconocido' }
$script:Lock = $null

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Log([string]$Msg) {
  # Rotación: si el log supera LogMaxBytes, guarda una copia .1 y empieza de cero
  if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $LogMaxBytes) {
    Move-Item -Force $LogFile "$LogFile.1"
  }
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $HostTag, $Msg
  Add-Content -Path $LogFile -Value $line
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

function Rebase-Remote {
  & git -c http.version=HTTP/1.1 pull --rebase --autostash -q origin $Branch
  if ($LASTEXITCODE -ne 0) {
    & git rebase --abort 2>$null
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
