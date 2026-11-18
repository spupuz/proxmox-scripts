#!/usr/bin/env bash
# Regression test: the report phase of lxc-updater.sh / lxc-cleanup.sh must
# survive `set -e` when at least one container was excluded.
#
# Both scripts re-enable errexit (`set -e`) immediately before the "Count
# excluded for reporting" loop. That loop used `((excluded_count++))`, which
# returns exit status 1 while the counter is still 0. Under errexit that aborts
# the run before the report is assembled and the notification is sent, so any
# host with EXCLUDED_CTIDS silently lost its report.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
fail=0

# Extract the real report phase from a script: from the `local total_processed=`
# line through the end of main(). This runs the shipped code, not a paraphrase.
extract_report_phase() {
  # From the `local total_processed=` line up to (not including) the brace that
  # closes main(), so the caller can wrap it in its own function body.
  awk '/^  local total_processed=/{p=1} p && /^}/{exit} p{print}' "$1"
}

run_phase() {
  local label="$1" phase="$2"
  local tmp phase_sh dir out rc

  tmp=$(mktemp -d)
  dir="$tmp/ct"
  mkdir -p "$dir"
  # One container updated, one excluded via EXCLUDED_CTIDS.
  printf '%s\n' '• 101 (web): ✅ App + OS Updated' > "$dir/101"
  printf '%s\n' '• 100 (db): ⏭️ Excluded' > "$dir/100"

  phase_sh="$tmp/phase.sh"
  {
    echo 'set -Eeuo pipefail'
    echo 'log() { :; }'
    echo "tmp_dir='$dir'"
    echo 'lxc_list=("101:web" "100:db")'
    echo 'report=""'
    # Initialised exactly as the scripts declare them, so the extracted phase
    # sees the same state it sees in production.
    echo 'ok_count=1'
    echo 'skip_count=0'
    echo 'no_method_count=0'
    echo 'fail_count=0'
    echo 'clean_count=1'
    echo 'excluded_count=0'
    echo 'human_readable() { printf "%s" "$1"; }'
    echo 'send_notification() { printf "NOTIFY_SENT\n"; }'
    echo 'main() {'
    printf '%s\n' "$phase"
    echo '  printf "REPORT_PHASE_OK excluded=%s\n" "$excluded_count"'
    echo '}'
    echo 'main "$@"'
  } > "$phase_sh"

  out=$(bash "$phase_sh" 2>&1); rc=$?
  rm -rf "$tmp"

  if (( rc != 0 )); then
    echo "❌ $label: report phase aborted under set -e (rc=$rc) — no report sent"
    fail=1
    return
  fi
  if [[ "$out" != *"REPORT_PHASE_OK"* ]]; then
    echo "❌ $label: report phase did not complete (out=$out)"
    fail=1
    return
  fi
  if [[ "$out" != *"excluded=1"* ]]; then
    echo "❌ $label: excluded counter wrong (out=$out, expected excluded=1)"
    fail=1
    return
  fi
  echo "✅ $label: report phase completes and counts exclusions ($out)"
}

for src in lxc-updater.sh lxc-cleanup.sh; do
  if [[ ! -f "$repo/$src" ]]; then
    echo "❌ $src not found"
    fail=1
    continue
  fi
  phase=$(extract_report_phase "$repo/$src")
  if [[ -z "$phase" ]]; then
    echo "❌ $src: could not extract report phase"
    fail=1
    continue
  fi
  run_phase "$src" "$phase"
done

# Static backstop: no post-increment may survive in an errexit-enabled region,
# because everything after the script's `set -e` line runs with errexit active.
# Comments are stripped first so prose mentioning the pattern cannot trip it.
for src in lxc-updater.sh lxc-cleanup.sh; do
  awk -v f="$src" '
    { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
    line ~ /^[[:space:]]*set -e[[:space:]]*$/ { seen = NR }
    line ~ /\(\([A-Za-z_][A-Za-z0-9_]*\+\+\)\)/ && seen {
      printf "❌ %s:%d post-increment after set -e: %s\n", f, NR, $0
      bad = 1
    }
    END { exit bad }
  ' "$repo/$src" || fail=1
done

if (( fail == 0 )); then
  echo "✅ Excluded-count report tests passed."
fi
exit "$fail"