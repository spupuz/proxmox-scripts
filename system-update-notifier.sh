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
apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 >/dev/null 2>&1

log INFO "Simulating upgrade to list packages..."
UPGRADE_LIST=$(apt-get -s dist-upgrade | grep -E '^Inst' | awk '{print $2}')
if [[ -z "$UPGRADE_LIST" ]]; then
  REPORT="*✅ $HOSTNAME*: System already up‑to‑date"
  send_telegram "$REPORT"
  exit 0
fi

log INFO "Performing dist-upgrade..."
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" >/dev/null 2>&1

# Determine if a kernel package was upgraded
KERNEL_UPDATED=false
for pkg in $UPGRADE_LIST; do
  if [[ $pkg == linux-image-* || $pkg == linux-headers-* ]]; then
    KERNEL_UPDATED=true; break
  fi
done

# Check reboot required flag
REBOOT_REQ=""
if [[ -f /var/run/reboot-required ]]; then REBOOT_REQ="(reboot required)"; fi

# Build telegram message
REPORT="*🔔 System Update Report: $HOSTNAME*\n\n"
REPORT+="*Installed packages:*\n"
for pkg in $UPGRADE_LIST; do REPORT+="- $pkg\n"; done
if $KERNEL_UPDATED; then
  REPORT+="\n⚠️ Kernel packages upgraded. Reboot may be required $REBOOT_REQ\n"
else
  REPORT+="\n✅ No kernel updates.\n"
fi

send_telegram "$REPORT"
