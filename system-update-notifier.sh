#!/bin/bash
# System Update Notifier
# Updates the host system via apt and sends a Telegram notification.

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- LOGGING ---
LOG_STDOUT="${LOG_STDOUT:-yes}"
log(){
  local lvl="${1:-INFO}"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local msg="${ts} [${lvl}] $*"
  [[ "$LOG_STDOUT" == "yes" ]] && echo "$msg" >&2
  command -v logger &>/dev/null && logger -t "system-update-notifier" -p "user.${lvl,,}" "$*" 2>/dev/null || true
}

# --- CONFIGURATION ---
TOKEN=""
CHAT_ID=""
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/telegram.conf" ]]; then
  source "${SCRIPT_DIR}/telegram.conf"
elif [[ -f "/etc/pve-telegram.conf" ]]; then
  source "/etc/pve-telegram.conf"
fi
TOKEN="${TOKEN:-}"; CHAT_ID="${CHAT_ID:-}"; HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"

# --- TELEGRAM SEND ---
send_telegram(){
  local message="$1"
  [[ -z "$TOKEN" || -z "$CHAT_ID" ]] && { log WARN "Telegram config missing"; return 0; }
  local URL="https://api.telegram.org/bot${TOKEN}/sendMessage"
  local RESPONSE=$(curl -s -X POST "$URL" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "text=$message")
  [[ $RESPONSE != *'"ok":true'* ]] && log ERROR "Telegram error: $RESPONSE" || log INFO "Telegram sent"
}

# --- PRE-FLIGHT CHECKS ---
if [[ $EUID -ne 0 ]]; then log ERROR "Must run as root"; exit 1; fi
command -v apt-get &>/dev/null || { log ERROR "apt-get not found"; exit 1; }

log INFO "Running apt update..."
echo "  📦 Fetching package lists..." >&2
apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 2>&1 | grep -E '(^Get:|^Hit:|^Reading)' >&2

log INFO "Checking for available upgrades..."
echo "  🔍 Analyzing upgrade candidates..." >&2
UPGRADE_LIST=$(apt-get -s dist-upgrade | grep -E '^Inst' | awk '{print $2}')
if [[ -z "$UPGRADE_LIST" ]]; then
  echo "  ✅ No upgrades available" >&2
  REPORT="*✅ $HOSTNAME*: System already up‑to‑date"
  send_telegram "$REPORT"
  log INFO "System is already up to date"
  exit 0
fi

PACKAGE_COUNT=$(echo "$UPGRADE_LIST" | wc -w)
log INFO "Found $PACKAGE_COUNT packages to upgrade"
echo "  📋 Packages to upgrade ($PACKAGE_COUNT):" >&2
echo "$UPGRADE_LIST" | tr ' ' '\n' | sed 's/^/    ✓ /' >&2

echo "  🔧 Starting installation..." >&2
log INFO "Installing system updates..."
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" 2>&1 | tee /tmp/apt-upgrade.log | grep -E '^(Get|Setting|Processing|done|Unpacking|Setting|upgraded|removed|newly installed|Preparing|^$)' >&2
echo "  ✅ Installation completed" >&2

# Determine if a kernel package was upgraded
KERNEL_UPDATED=false
for pkg in $UPGRADE_LIST; do
  if [[ $pkg == linux-image-* || $pkg == linux-headers-* || $pkg == proxmox-kernel-* || $pkg == proxmox-headers-* || $pkg == pve-kernel-* || $pkg == pve-headers-* ]]; then
    KERNEL_UPDATED=true; break
  fi
done

# Check reboot required flag
REBOOT_REQ=""
if [[ -f /var/run/reboot-required ]]; then REBOOT_REQ=" (reboot required)"; fi

# Build telegram message with package list
REPORT="*🔔 System Update Report: $HOSTNAME*"$'\n\n'
REPORT+="*$PACKAGE_COUNT packages installed:*"$'\n'
for pkg in $UPGRADE_LIST; do 
  REPORT+="• $pkg"$'\n'
done

REBOOT_NOTE=""
if $KERNEL_UPDATED && [[ -n "$REBOOT_REQ" ]]; then
  REBOOT_NOTE="⚠️ Kernel aggiornato — riavvio necessario"
elif $KERNEL_UPDATED && [[ -z "$REBOOT_REQ" ]]; then
  REBOOT_NOTE="⚠️ Kernel aggiornato — riavvio potrebbe essere necessario"
elif ! $KERNEL_UPDATED && [[ -n "$REBOOT_REQ" ]]; then
  REBOOT_NOTE="⚠️ Riavvio ancora necessario (kernel aggiornato in precedenza)"
else
  REBOOT_NOTE="✅ Nessun aggiornamento kernel"
fi
REPORT+=$'\n'"$REBOOT_NOTE"

log INFO "Upgrade completed"
echo "  📧 Sending Telegram notification..." >&2

send_telegram "$REPORT"
