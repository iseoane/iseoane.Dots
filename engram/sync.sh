#!/usr/bin/env bash
# Engram sync — sincroniza tu "cerebro" Engram entre máquinas vía un repo git privado.
# Usa el git-sync nativo de Engram (chunks append-only), NO la base de datos en crudo.
# Uso:  sync.sh pull   (SessionStart: trae chunks del repo e impórtalos a la BD local)
#       sync.sh push   (Stop / SessionEnd: exporta memorias nuevas, commitea y sube)

# Rotar si el log supera 1 MB
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > 1048576 )); then
  mv "$LOG_FILE" "${LOG_FILE}.1"
fi

set -uo pipefail   # sin -e: gestionamos los fallos a mano para no romper la sesión

# ── Configuración (ajusta o exporta como variables de entorno) ───────────────
REPO_DIR="${ENGRAM_SYNC_DIR:-$HOME/.engram-sync}"   # clon del repo "cerebro"
BRANCH="${ENGRAM_BRANCH:-main}"
ENGRAM_BIN="${ENGRAM_BIN:-engram}"                  # ruta absoluta si no está en el PATH del hook
LOCK_FILE="${ENGRAM_LOCK:-$HOME/.engram-sync/.sync.lock}"
LOG_FILE="${ENGRAM_LOG:-$HOME/.engram/sync.log}"
MAX_PUSH_RETRIES="${ENGRAM_PUSH_RETRIES:-3}"
HOST="$(hostname -s 2>/dev/null || echo desconocido)"

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$HOST" "$*" >> "$LOG_FILE"; }

# Registra el problema pero NUNCA rompe la sesión de Claude Code (sale con 0).
die_soft() { log "WARN: $*"; exit 0; }

ensure_repo() {
  command -v "$ENGRAM_BIN" >/dev/null 2>&1 || die_soft "binario engram no encontrado en el PATH del hook"
  cd "$REPO_DIR" 2>/dev/null || die_soft "repo no encontrado: $REPO_DIR"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die_soft "no es un repo git: $REPO_DIR"
  return 0
}

commit_if_changes() {
  git add -A
  if git diff --cached --quiet; then
    log "Sin chunks nuevos que commitear."
  else
    git commit -q -m "engram sync desde $HOST @ $(date '+%F %T')" \
      && log "Chunks nuevos commiteados." \
      || die_soft "el commit falló"
  fi
  return 0
}

# Trae el remoto con rebase. Como los chunks son append-only, los conflictos
# reales se limitan al manifest.json; si los hay, abortamos y dejamos limpio.
rebase_remote() {
  if ! git -c http.version=HTTP/1.1 pull --rebase --autostash -q origin "$BRANCH"; then
    git rebase --abort 2>/dev/null || true
    return 1
  fi
  return 0
}

# ── Acciones ──────────────────────────────────────────────────────────────────
do_pull() {
  ensure_repo
  rebase_remote || die_soft "git pull --rebase fallo/conflicto en pull"
  # Importa a la BD local los chunks que aun no esten importados.
  "$ENGRAM_BIN" sync --import >/dev/null 2>&1 && log "Import OK." || log "WARN: engram sync --import devolvio error"
  log "Pull OK."
}

do_push() {
  ensure_repo
  # Exporta las memorias nuevas de la BD local a .engram/chunks + manifest.json.
  "$ENGRAM_BIN" sync --all >/dev/null 2>&1 || log "WARN: engram sync --all devolvio error"
  commit_if_changes
  local attempt=1
  while (( attempt <= MAX_PUSH_RETRIES )); do
    rebase_remote || die_soft "git pull --rebase fallo/conflicto (intento $attempt); commit local guardado para el proximo sync"
    # Importa lo que haya traido el rebase de la otra maquina (idempotente).
    "$ENGRAM_BIN" sync --import >/dev/null 2>&1 || true
    if git -c http.version=HTTP/1.1 push -q origin "$BRANCH"; then
      log "Push OK (intento $attempt)."
      return 0
    fi
    log "Push rechazado (intento $attempt) reintento tras rebase."
    (( attempt++ )) || true
  done
  die_soft "el push fallo tras $MAX_PUSH_RETRIES intentos"
}

# ── Lock + dispatch ───────────────────────────────────────────────────────────
CMD="${1:-}"
mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$LOG_FILE")"

# flock se auto-libera al terminar el script (al cerrarse el fd 9).
exec 9>"$LOCK_FILE"
if ! flock -w 20 9; then
  log "Sync ocupado >20s, omito ($CMD)."
  exit 0
fi

case "$CMD" in
  pull) do_pull ;;
  push) do_push ;;
  *)    echo "uso: $0 {pull|push}" >&2; exit 2 ;;
esac
