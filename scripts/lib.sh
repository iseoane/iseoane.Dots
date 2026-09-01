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

has_windows_mount() {
  [ -d "$WIN_HOME" ]
}
