#!/usr/bin/env bash
set -e

echo "Running UX Mirror tests..."

# Ensure we have the log outputs in the updater scripts
if ! grep -q 'log INFO "✅ Proxmox Host: Up to date"' pve-update-notifier.sh; then
    echo "❌ Error: pve-update-notifier.sh is missing ✅ UX mirror"
    false
fi
if ! grep -q 'log WARN "⚠️ Proxmox Host: $HOST_UPDATES_CLEAN updates available"' pve-update-notifier.sh; then
    echo "❌ Error: pve-update-notifier.sh is missing ⚠️ UX mirror"
    false
fi

if ! grep -q 'log ERROR "❌ ID $CTID ($CTNAME): Error checking updates (Container offline or timed out)"' pve-update-notifier.sh; then
    echo "❌ Error: pve-update-notifier.sh is missing ❌ LXC UX mirror"
    false
fi

if ! grep -q 'log INFO "✅ Proxmox Host: System is up to date"' lxc-updater.sh; then
    echo "❌ Error: lxc-updater.sh is missing ✅ UX mirror"
    false
fi

if ! grep -F 'log ERROR "${first_line#* ($ctname): }" >&3' lxc-updater.sh; then
    echo "❌ Error: lxc-updater.sh is missing LXC UX mirror"
    false
fi

if ! grep -F 'log ERROR "${first_line#* ($ctname): }" >&3' lxc-cleanup.sh; then
    echo "❌ Error: lxc-cleanup.sh is missing LXC UX mirror"
    false
fi

echo "✅ All UX mirror tests passed!"
