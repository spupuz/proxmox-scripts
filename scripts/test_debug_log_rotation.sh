#!/usr/bin/env bash
# Regression test: debug-log rotation must not abort the script under `set -e`.
# `rotate_debug_logs` used a post-increment arithmetic command whose first
# evaluation is `((0++))` -> exit status 1, which `set -e` treats as a fatal
# error. Enabling DEBUG_LOG=yes therefore killed the whole run silently.
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

for src in lxc-cleanup.sh lxc-updater.sh; do
  if [[ ! -f "$src" ]]; then
    echo "❌ $src not found"
    fail=1
    continue
  fi

  rm -f "$tmp"/fn.sh "$tmp"/test.debug*.log
  for i in 1 2 3; do : > "$tmp/test.debug.$i.log"; done
  sed -n '/^rotate_debug_logs() {/,/^}/p' "$src" > "$tmp/fn.sh"

  if ! DEBUG_LOG=yes DEBUG_LOG_FILE="$tmp/test.debug.log" DEBUG_LOG_MAX_FILES=1 \
      bash -c 'set -Eeuo pipefail; source "$1"; rotate_debug_logs' _ "$tmp/fn.sh"; then
    echo "❌ $src: rotate_debug_logs aborts the script under set -e"
    fail=1
    continue
  fi

  remaining=$(find "$tmp" -maxdepth 1 -name 'test.debug*.log' -type f | wc -l)
  if (( remaining != 1 )); then
    echo "❌ $src: expected 1 rotated log file, found $remaining"
    fail=1
  fi
done

if (( fail == 0 )); then
  echo "✅ Debug log rotation tests passed."
fi
exit "$fail"
