#!/usr/bin/env bash
# CLI argument UX tests: --help must always work, unknown options must be rejected.
set -e
cd "$(dirname "$0")/.."

fail=0

for script in lxc-updater.sh lxc-cleanup.sh pve-update-notifier.sh system-update-notifier.sh; do
    # --help must print usage and exit 0 without needing root or a PVE/apt host
    set +e
    out=$(timeout 30 bash "$script" --help 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        echo "❌ Error: $script --help exited $rc (expected 0)"
        fail=1
    elif ! grep -q "Usage: $script" <<<"$out"; then
        echo "❌ Error: $script --help did not print usage text"
        fail=1
    fi

    # An unknown option must fail loudly instead of silently running the script
    set +e
    out=$(timeout 30 bash "$script" --bogus 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 2 ]]; then
        echo "❌ Error: $script --bogus exited $rc (expected 2)"
        fail=1
    elif ! grep -q '❌ Unknown option: --bogus' <<<"$out"; then
        echo "❌ Error: $script --bogus did not report the unknown option"
        fail=1
    elif ! grep -q "Try $script --help for usage" <<<"$out"; then
        echo "❌ Error: $script --bogus did not hint at --help"
        fail=1
    fi
done

if [[ $fail -ne 0 ]]; then
    exit 1
fi

echo "✅ All CLI argument UX tests passed!"