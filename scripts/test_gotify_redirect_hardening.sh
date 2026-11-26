#!/bin/bash
# Test that the Gotify curl invocation refuses HTTP redirects.
# Mirrors the --max-redirs 0 hardening applied in send_gotify() of all four
# main scripts: the X-Gotify-Key token must never be redirected to a plaintext
# http:// host (--proto '=https' only constrains the initial URL).

fail=0

for script in lxc-updater.sh lxc-cleanup.sh system-update-notifier.sh pve-update-notifier.sh; do
    # The Gotify curl_flags array must include --max-redirs 0
    if ! grep -q 'local curl_flags=(-s --connect-timeout 10 --max-time 30 --max-redirs 0)' "$script"; then
        echo "❌ Error: $script send_gotify() is missing --max-redirs 0 in curl_flags"
        fail=1
    fi
done

if [[ $fail -eq 0 ]]; then
    echo "✅ Gotify redirect-downgrade hardening tests passed."
fi
exit $fail