#!/usr/bin/env bash
#
# Migrate legacy Telegram/Gotify config files into the unified config.conf
#
# Usage: ./migrate-config.sh [directory]
#   directory: optional path where scripts/configs live (default: script dir)

set -euo pipefail

TARGET_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Collect legacy files
legacy=()
for f in "$TARGET_DIR/proxmox-telegram.conf" "$TARGET_DIR/telegram.conf" "/etc/pve-telegram.conf" "$TARGET_DIR/gotify.conf" "/etc/pve-gotify.conf"; do
  [[ -f "$f" ]] && legacy+=("$f")
done

if [[ ${#legacy[@]} -eq 0 ]]; then
  echo "No legacy config files found. Nothing to migrate."
  exit 0
fi

out="$TARGET_DIR/config.conf"
if [[ -f "$out" ]]; then
  echo "config.conf already exists at $out - aborting to avoid overwriting."
  echo "Remove or rename it first if you want to regenerate."
  exit 1
fi

{
  echo "# Unified configuration (migrated from legacy files)"
  echo "# Source files: ${legacy[*]}"
  echo ""
  for f in "${legacy[@]}"; do
    echo "# --- migrated from $f ---"
    cat "$f"
    echo ""
  done
} > "$out"
chmod 600 "$out"
echo "Migrated ${#legacy[@]} legacy file(s) into $out"
echo "You can now remove the legacy files if desired (kept for fallback)."
