#!/usr/bin/env bash
# Regression test: pct list VMID numeric validation (Sentinel).
# Ensures non-numeric VMIDs are skipped before arithmetic / pct exec / file paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

for src in lxc-cleanup.sh lxc-updater.sh pve-update-notifier.sh; do
    if ! grep -q 'vmid.*=~ \^\[0-9\]+\$' "$SCRIPT_DIR/$src" 2>/dev/null; then
        echo "❌ $src: missing numeric VMID validation in pct list loop"
        fail=1
    else
        echo "✅ $src: numeric VMID validation present"
    fi
done

# Functional check: the regex correctly classifies inputs
test_id() {
    local id="$1" expected="$2"
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        actual="valid"
    else
        actual="skip"
    fi
    if [[ "$actual" != "$expected" ]]; then
        echo "❌ VMID '$id': expected '$expected', got '$actual'"
        fail=1
    fi
}

test_id "100" "valid"
test_id "999" "valid"
test_id "0"   "valid"
test_id "12a" "skip"
test_id "a12" "skip"
test_id ''    "skip"
test_id '1;rm -rf /' "skip"

if [[ $fail -eq 0 ]]; then
    echo "✅ All ctid validation tests passed."
    exit 0
else
    echo "❌ Some tests failed."
    exit 1
fi