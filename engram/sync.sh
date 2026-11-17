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

# Guarda el ultimo resultado en $STATUS_FILE (lo pinta la statusline) y, con
# --hook, lo emite como systemMessage para Claude Code. Nunca falla.
STATUS_FILE="${ENGRAM_STATUS:-$HOME/.engram/sync.status}"
HOOK=0; WARNINGS=0; LAST_WARNING=""
show_result() {
  local line="🧠 $CMD $1"
  [[ "$1" != OK && -n "${2:-}" ]] && line="$line — $2"
  printf '%s
' "$line" > "$STATUS_FILE" 2>/dev/null || true
  if (( HOOK )); then
    jq -cn --arg m "$line" '{systemMessage: $m}' 2>/dev/null || true
  fi
}

# Registra el problema pero NUNCA rompe la sesión de Claude Code (sale con 0).
die_soft() { log "WARN: $*"; show_result KO "$*"; exit 0; }

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

# Ejecuta engram y vuelca su salida de error al log. Antes se descartaba con
# 2>/dev/null y el log solo decia "devolvio error", sin la causa real.
run_engram() {
  local out rc
  out="$("$ENGRAM_BIN" "$@" 2>&1)"; rc=$?
  if (( rc != 0 )); then
    LAST_WARNING="engram $*: $(printf '%s' "$out" | tail -n 3 | tr '
' ' ')"
    log "WARN: engram $* devolvio error (rc=$rc): $LAST_WARNING"
    (( WARNINGS++ )) || true
  fi
  return $rc
}

# Un merge o rebase que quedo a medias (proceso cortado, hook interrumpido)
# deja MERGE_HEAD y marcadores de conflicto en el working tree. Si el
# siguiente commit_if_changes hace 'git add -A', cierra ese merge con los
# marcadores dentro y rompe manifest.json para todas las maquinas. Por eso se
# aborta cualquier operacion pendiente antes de tocar el repo.
recover_git_state() {
  local gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 0
  if [[ -f "$gitdir/MERGE_HEAD" ]]; then
    git merge --abort >/dev/null 2>&1 || git reset -q --merge >/dev/null 2>&1
    log "WARN: merge a medias detectado y abortado."
  fi
  if [[ -d "$gitdir/rebase-merge" || -d "$gitdir/rebase-apply" ]]; then
    git rebase --abort >/dev/null 2>&1 || true
    log "WARN: rebase a medias detectado y abortado."
  fi
  return 0
}

# manifest.json debe ser JSON valido sin marcadores de conflicto; si no, ni
# engram puede exportar ni se debe commitear nada encima.
manifest_ok() {
  local manifest=".engram/manifest.json"
  [[ -f "$manifest" ]] || return 0
  if grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$manifest"; then return 1; fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$manifest" >/dev/null 2>&1 || return 1
  fi
  return 0
}

commit_if_changes() {
  manifest_ok || die_soft "manifest.json invalido (marcadores de conflicto o JSON roto); no commiteo. Requiere reparacion manual."
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

# Trae el remoto con rebase, distinguiendo la CAUSA del fallo. Como los chunks
# son append-only, los conflictos reales se limitan al manifest.json.
#
# El diseño anterior usaba 'pull --rebase' (fetch+rebase en un paso) y devolvia
# el mismo codigo 1 tanto para un hipo de red en el fetch como para un conflicto
# genuino, asi que el hook gritaba WARN "fallo/conflicto" ante fallos benignos
# que se autocuran. Ahora separamos fetch de rebase para clasificar:
#   0 -> rebase OK
#   1 -> transitorio (el fetch a GitHub no respondio; se reintenta con backoff)
#   2 -> conflicto de rebase REAL (requiere revision manual)
REBASE_FETCH_RETRIES="${ENGRAM_FETCH_RETRIES:-3}"
rebase_remote() {
  local i=1
  while (( i <= REBASE_FETCH_RETRIES )); do
    git -c http.version=HTTP/1.1 fetch -q origin "$BRANCH" 2>/dev/null && break
    (( i < REBASE_FETCH_RETRIES )) && sleep "$i"   # backoff 1s, 2s, ...
    (( i++ )) || true
  done
  (( i > REBASE_FETCH_RETRIES )) && return 1        # el fetch nunca funciono
  # Fetch OK: rebasa sobre lo traido. Un fallo aqui SI es un conflicto real.
  git rebase --autostash -q "origin/$BRANCH" 2>/dev/null && return 0
  git rebase --abort 2>/dev/null || true
  merge_manifest && return 0
  return 2
}

# Plan B cuando el rebase choca: merge con origin y, si el unico conflicto es
# .engram/manifest.json, une los chunks de ambos lados por id (append-only).
# Devuelve 0 si el merge quedo commiteado; si no, lo aborta y devuelve 1.
merge_manifest() {
  local manifest=".engram/manifest.json" conflicts n
  if git merge --no-edit -q "origin/$BRANCH" >/dev/null 2>&1; then
    log "Rebase fallo; merge limpio con origin."
    return 0
  fi
  conflicts="$(git diff --name-only --diff-filter=U 2>/dev/null)"
  if [[ "$conflicts" != "$manifest" ]] || ! command -v python3 >/dev/null 2>&1; then
    git merge --abort 2>/dev/null || true
    return 1
  fi
  if ! n="$(python3 - "$manifest" <<'PY'
import json, subprocess, sys
path = sys.argv[1]
show = lambda stage: json.loads(subprocess.check_output(["git", "show", f":{stage}:{path}"]))
ours, theirs = show(2), show(3)
by_id = {c["id"]: c for c in ours["chunks"] + theirs["chunks"]}
ours["chunks"] = sorted(by_id.values(), key=lambda c: c["created_at"])
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(ours, f, indent=2)
    f.write("\n")
print(len(ours["chunks"]))
PY
)"; then
    git merge --abort 2>/dev/null || true
    return 1
  fi
  git add -- "$manifest" && git commit -q --no-edit || { git merge --abort 2>/dev/null || true; return 1; }
  log "Conflicto en manifest resuelto por union ($n chunks)."
}

# ── Acciones ──────────────────────────────────────────────────────────────────
do_pull() {
  ensure_repo
  recover_git_state
  rebase_remote
  case $? in
    1) log "Pull pospuesto (red transitoria); se reintenta en el proximo sync."; show_result PENDIENTE "sin red; se reintenta en el proximo sync"; exit 0 ;;
    2) die_soft "conflicto de rebase REAL en pull; requiere revision manual" ;;
  esac
  # Importa a la BD local los chunks que aun no esten importados.
  run_engram sync --import && log "Import OK."
  log "Pull OK."
  if (( WARNINGS )); then show_result KO "$LAST_WARNING"; else show_result OK "memorias importadas"; fi
}

do_push() {
  ensure_repo
  recover_git_state
  manifest_ok || die_soft "manifest.json invalido (marcadores de conflicto o JSON roto); requiere reparacion manual."
  # Exporta las memorias nuevas de la BD local a .engram/chunks + manifest.json.
  run_engram sync --all
  # Quita el grafo de relaciones de los chunks recién exportados (ver arriba).
  strip_relations
  commit_if_changes
  local attempt=1
  while (( attempt <= MAX_PUSH_RETRIES )); do
    rebase_remote
    case $? in
      1) log "Push pospuesto (red transitoria, intento $attempt); commit local intacto, se reintenta en el proximo sync."; show_result PENDIENTE "sin red; commit local guardado, se sube en el proximo sync"; exit 0 ;;
      2) die_soft "conflicto de rebase REAL en push; commit local intacto, requiere revision manual" ;;
    esac
    # Importa lo que haya traido el rebase de la otra maquina (idempotente).
    run_engram sync --import || true
    if git -c http.version=HTTP/1.1 push -q origin "$BRANCH"; then
      log "Push OK (intento $attempt)."
      if (( WARNINGS )); then show_result KO "push hecho, pero $LAST_WARNING"; else show_result OK "memorias subidas"; fi
      return 0
    fi
    log "Push rechazado (intento $attempt) reintento tras rebase."
    (( attempt++ )) || true
  done
  die_soft "el push fallo tras $MAX_PUSH_RETRIES intentos"
}

# ── Lock + dispatch ───────────────────────────────────────────────────────────
CMD="${1:-}"
DETACH=0
for arg in "${@:2}"; do
  case "$arg" in
    --hook) HOOK=1 ;;
    # Claude Code solo concede ~1,5 s a los hooks SessionEnd: relanza el sync
    # desacoplado de la sesion y sale enseguida.
    --detach) DETACH=1 ;;
  esac
done
if (( DETACH )); then
  nohup setsid "$0" "$CMD" >/dev/null 2>&1 < /dev/null &
  exit 0
fi
mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$LOG_FILE")"
prune_log

# flock se auto-libera al terminar el script (al cerrarse el fd 9).
exec 9>"$LOCK_FILE"
if ! flock -w 20 9; then
  log "Sync ocupado >20s, omito ($CMD)."
  show_result PENDIENTE "otro sync en curso; se omite"
  exit 0
fi

case "$CMD" in
  pull) do_pull ;;
  push) do_push ;;
  *)    echo "uso: $0 {pull|push}" >&2; exit 2 ;;
esac
