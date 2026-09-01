#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

source_file="$TEST_ROOT/repo-zshrc"
stale_target="$TEST_ROOT/home/.zshrc"
regular_target="$TEST_ROOT/home/.zprofile"
mkdir -p "$(dirname "$stale_target")"
printf 'repo config\n' > "$source_file"
ln -s "$TEST_ROOT/old-checkout/zsh/.zshrc" "$stale_target"
printf 'user config\n' > "$regular_target"

copy_with_backup "$source_file" "$stale_target"
copy_with_backup "$source_file" "$regular_target"

[ -f "$stale_target" ] && [ ! -L "$stale_target" ]
[ "$(cat "$stale_target")" = "repo config" ]
[ -f "$regular_target" ] && [ "$(cat "$regular_target")" = "repo config" ]

stale_backup="$(printf '%s\n' "$stale_target".bak-* )"
regular_backup="$(printf '%s\n' "$regular_target".bak-* )"
[ -L "$stale_backup" ]
[ "$(readlink "$stale_backup")" = "$TEST_ROOT/old-checkout/zsh/.zshrc" ]
[ -f "$regular_backup" ] && [ "$(cat "$regular_backup")" = "user config" ]

printf 'PASS: stale symlink and regular file were backed up before portable copies replaced them\n'
