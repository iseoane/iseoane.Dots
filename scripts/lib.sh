#!/usr/bin/env bash
# Shared helpers for sync-from-system.sh and apply-to-system.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIN_HOME="/mnt/c/Users/iseoane"

backup_if_needed() {
  # $1 = path to a file/dir that is about to be overwritten
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    local stamp backup counter
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="${target}.bak-${stamp}"
    counter=1
    while [ -e "$backup" ] || [ -L "$backup" ]; do
      backup="${target}.bak-${stamp}-${counter}"
      counter=$((counter + 1))
    done
    mv "$target" "$backup"
    echo "  backup -> $backup"
  fi
}

copy() {
  # $1 = source, $2 = destination
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp -r "$src" "$dst"
  echo "  copied: $src -> $dst"
}

copy_with_backup() {
  # $1 = source, $2 = destination
  backup_if_needed "$2"
  copy "$1" "$2"
}

upsert_managed_block() {
  # $1 = fragment, $2 = destination, $3 = stable block name
  # $4 = comment prefix (optional, defaults to #; use -- for Lua)
  # Replaces only our marked block and preserves all user-owned content.
  local src="$1" dst="$2" name="$3" prefix="${4:-#}" begin end tmp
  begin="${prefix} >>> iseoane.Dots: ${name} >>>"
  end="${prefix} <<< iseoane.Dots: ${name} <<<"
  mkdir -p "$(dirname "$dst")"
  touch "$dst"
  tmp="$(mktemp)"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skipping = 1; next }
    $0 == end { skipping = 0; next }
    !skipping { print }
  ' "$dst" >"$tmp"
  while [ -s "$tmp" ] && [ -z "$(tail -n 1 "$tmp")" ]; do
    sed -i '$d' "$tmp"
  done
  [ ! -s "$tmp" ] || printf '\n' >>"$tmp"
  {
    printf '%s\n' "$begin"
    cat "$src"
    printf '%s\n' "$end"
  } >>"$tmp"
  mv "$tmp" "$dst"
  echo "  merged block: $name -> $dst"
}

ensure_config_line() {
  # $1 = exact line, $2 = destination. Comments and unrelated flags survive.
  local line="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  touch "$dst"
  grep -Fxq -- "$line" "$dst" || printf '%s\n' "$line" >>"$dst"
  echo "  ensured: $line -> $dst"
}

prefer_config_line() {
  # $1 = exact preference, $2 = destination. Keeps comments and fallbacks,
  # but moves this value ahead of every other non-comment preference.
  local line="$1" dst="$2" tmp
  mkdir -p "$(dirname "$dst")"
  touch "$dst"
  tmp="$(mktemp)"
  awk -v wanted="$line" '
    $0 == wanted { next }
    !inserted && $0 !~ /^[[:space:]]*(#|$)/ { print wanted; inserted = 1 }
    { print }
    END { if (!inserted) print wanted }
  ' "$dst" >"$tmp"
  mv "$tmp" "$dst"
  echo "  preferred: $line -> $dst"
}

has_windows_mount() {
  [ -d "$WIN_HOME" ]
}
