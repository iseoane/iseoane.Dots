#!/usr/bin/env bash
# Shared helpers for sync-from-system.sh and apply-to-system.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIN_HOME="/mnt/c/Users/iseoane"

backup_if_needed() {
  # $1 = path to a file/dir that is about to be overwritten
  local target="$1"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    mv "$target" "${target}.bak-${stamp}"
    echo "  backup -> ${target}.bak-${stamp}"
  fi
}

symlink() {
  # $1 = source (repo file), $2 = destination (live path)
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
    echo "  ok (already linked): $dst"
    return
  fi
  backup_if_needed "$dst"
  ln -s "$src" "$dst"
  echo "  linked: $dst -> $src"
}

copy() {
  # $1 = source, $2 = destination
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp -r "$src" "$dst"
  echo "  copied: $src -> $dst"
}

has_windows_mount() {
  [ -d "$WIN_HOME" ]
}
