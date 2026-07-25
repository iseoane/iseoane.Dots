#!/usr/bin/env bash
# Engram sync — sincroniza tu "cerebro" Engram entre máquinas vía un repo git privado.
# Usa el git-sync nativo de Engram (chunks append-only), NO la base de datos en crudo.
# Uso:  sync.sh pull   (SessionStart: trae chunks del repo e impórtalos a la BD local)
#       sync.sh push   (Stop / SessionEnd: exporta memorias nuevas, commitea y sube)

set -uo pipefail   # sin -e: gestionamos los fallos a mano para no romper la sesión

# ── Configuración (ajusta o exporta como variables de entorno) ───────────────
REPO_DIR="${ENGRAM_SYNC_DIR:-$HOME/.engram-sync}"   # clon del repo "cerebro"
BRANCH="${ENGRAM_BRANCH:-main}"
ENGRAM_BIN="${ENGRAM_BIN:-engram}"                  # ruta absoluta si no está en el PATH del hook
LOCK_FILE="${ENGRAM_LOCK:-$HOME/.engram-sync/.sync.lock}"
LOG_FILE="${ENGRAM_LOG:-$HOME/.engram/sync.log}"
LOG_RETENTION_DAYS="${ENGRAM_LOG_RETENTION_DAYS:-30}"
MAX_PUSH_RETRIES="${ENGRAM_PUSH_RETRIES:-3}"
HOST="$(hostname -s 2>/dev/null || echo desconocido)"

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$HOST" "$*" >> "$LOG_FILE"; }

# Registra el problema pero NUNCA rompe la sesión de Claude Code (sale con 0).
die_soft() { log "WARN: $*"; exit 0; }

# Poda el log a los últimos N días (las líneas empiezan por 'YYYY-MM-DD ', que
# ordena lexicográficamente = cronológicamente). El bloque de rotación anterior
# vivía ANTES de definir $LOG_FILE, así que nunca se ejecutaba y el log crecía
# sin límite. Las líneas sin fecha al inicio se conservan por seguridad.
prune_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local cutoff tmp
  cutoff="$(date -d "${LOG_RETENTION_DAYS} days ago" '+%F' 2>/dev/null)" || return 0
  tmp="${LOG_FILE}.tmp.$$"
  awk -v c="$cutoff" '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / { if (substr($0,1,10) >= c) print; next }
    { print }
  ' "$LOG_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$LOG_FILE" || rm -f "$tmp"
}

ensure_repo() {
  command -v "$ENGRAM_BIN" >/dev/null 2>&1 || die_soft "binario engram no encontrado en el PATH del hook"
  cd "$REPO_DIR" 2>/dev/null || die_soft "repo no encontrado: $REPO_DIR"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die_soft "no es un repo git: $REPO_DIR"
  return 0
}

# El git-sync comparte observaciones/sesiones/prompts (el contenido real de
# memoria) pero NO el grafo de relaciones de Engram. Motivo: una mutación de
# relación puede apuntar a una observación que Engram nunca exporta a chunks
# (existe solo en la BD de una máquina), y su precondición de FK entonces
# rompe 'engram sync --import' en la otra máquina. Las relaciones son metadatos
# advisory (related/not_conflict/compatible/...) que cada máquina regenera sola
# vía 'conflicts scan'/mem_judge, así que las quitamos de los chunks recién
# exportados antes de commitear. Idempotente: solo reescribe chunks que aún
# contienen relaciones, así que un chunk ya limpio no genera diff.
strip_relations() {
  command -v python3 >/dev/null 2>&1 || { log "WARN: python3 ausente; guard de relaciones omitido"; return 0; }
  python3 - "$REPO_DIR/.engram/chunks" <<'PY' 2>/dev/null || log "WARN: guard de relaciones fallo"
import gzip, json, glob, os, sys
chunks_dir = sys.argv[1]
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
PY
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
  # Quita el grafo de relaciones de los chunks recién exportados (ver arriba).
  strip_relations
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
prune_log

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
