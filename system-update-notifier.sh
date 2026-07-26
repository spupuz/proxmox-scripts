#!/bin/bash
# System Update Notifier
# Updates the host system via apt and sends a Telegram notification.

SCRIPT_VERSION="v0.5.2"

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
AUTO_UPDATE="${AUTO_UPDATE:-no}" # Set to "yes" to enable automatic script updates from GitHub

# --- TELEGRAM SEND ---
send_telegram(){
  local message="$1"
  [[ -z "$TOKEN" || -z "$CHAT_ID" ]] && { log WARN "Telegram config missing, skipping notification. Please set TOKEN and CHAT_ID in telegram.conf or /etc/pve-telegram.conf"; return 0; }
  local URL="https://api.telegram.org/bot${TOKEN}/sendMessage"
  # 🛡️ Sentinel Security Fix: Prevent TOKEN leakage in process list (ps aux).
  # Pass URL with token via stdin to curl using -K to hide it from command line arguments.
  local RESPONSE=$(echo "url = \"$URL\"" | curl -s -K - -X POST \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "text=$message")
  [[ $RESPONSE != *'"ok":true'* ]] && { log ERROR "Telegram error: $RESPONSE"; echo "❌ Telegram Error: $RESPONSE" >&2; } || log INFO "Telegram sent"
}

# --- AUTO-UPDATE ---
version_compare() {
  local v1="${1#v}" v2="${2#v}"
  local IFS=.
  read -r major1 minor1 patch1 <<< "$v1"
  read -r major2 minor2 patch2 <<< "$v2"

  # Strip non-numeric characters to prevent arbitrary code execution in arithmetic evaluation
  major1=${major1//[^0-9]/}; minor1=${minor1//[^0-9]/}; patch1=${patch1//[^0-9]/}
  major2=${major2//[^0-9]/}; minor2=${minor2//[^0-9]/}; patch2=${patch2//[^0-9]/}

  major1=${major1:-0}; minor1=${minor1:-0}; patch1=${patch1:-0}
  major2=${major2:-0}; minor2=${minor2:-0}; patch2=${patch2:-0}

  if (( major1 > major2 )); then return 1; fi
  if (( major1 < major2 )); then return 2; fi
  if (( minor1 > minor2 )); then return 1; fi
  if (( minor1 < minor2 )); then return 2; fi
  if (( patch1 > patch2 )); then return 1; fi
  if (( patch1 < patch2 )); then return 2; fi
  return 0
}

auto_update() {
  local force="${1:-no}"
  local auto_update_enabled="${AUTO_UPDATE:-no}"

  local latest_tag
  latest_tag=$(curl -sI --connect-timeout 5 --max-time 10 \
    "https://github.com/spupuz/proxmox-scripts/releases/latest" \
    | grep -i '^location:' | sed 's|.*/tag/||' | tr -d '\r')

  if [[ -z "$latest_tag" ]]; then
    log INFO "Could not determine latest version from GitHub (or GitHub not reachable), proceeding with current version ($SCRIPT_VERSION)"
    return 0
  fi

  if [[ ! "$latest_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log ERROR "Invalid version tag format received from GitHub: $latest_tag"
    return 0
  fi

  if [[ "$latest_tag" == "$SCRIPT_VERSION" ]]; then
    log INFO "Script is up to date ($SCRIPT_VERSION)"
    return 0
  fi

  if version_compare "$latest_tag" "$SCRIPT_VERSION"; then
    log INFO "Script is up to date ($SCRIPT_VERSION >= $latest_tag)"
    return 0
  fi

  local script_name
  script_name="$(basename "${BASH_SOURCE[0]}")"

  log INFO "New version available: $latest_tag (current: $SCRIPT_VERSION)"

  if [[ "$force" == "no" && "$auto_update_enabled" == "no" ]]; then
    log INFO "Auto-update is disabled. Sending update available notification..."
    send_telegram "⚠️ *Script Update Available*

📜 \`${script_name}\`
📌 Current: \`${SCRIPT_VERSION}\`
🆕 Latest: \`${latest_tag}\`

Run \`bash ${script_name} --update\` to install."
    return 0
  fi

  log INFO "Downloading update..."

  local tmp_file
  tmp_file=$(mktemp "/tmp/${script_name}.XXXXXX") || return 1

  if curl -sL --connect-timeout 5 --max-time 30 \
    -o "$tmp_file" \
    "https://raw.githubusercontent.com/spupuz/proxmox-scripts/${latest_tag}/${script_name}"; then

    if head -1 "$tmp_file" | grep -q '^#!'; then
      cp "${BASH_SOURCE[0]}" "${BASH_SOURCE[0]}.bak"
      mv "$tmp_file" "${BASH_SOURCE[0]}"
      chmod +x "${BASH_SOURCE[0]}"
      log INFO "Script updated to $latest_tag"
      send_telegram "✅ *Script Updated*

📜 \`${script_name}\`
📌 \`${SCRIPT_VERSION}\` → 🆕 \`${latest_tag}\`"
      if [[ "${force}" == "yes" ]]; then
        echo "Updated to $latest_tag" >&2
        exec "${BASH_SOURCE[0]}"
      fi
      log INFO "Re-executing..."
      exec "${BASH_SOURCE[0]}" "$@"
    else
      log ERROR "Downloaded file appears invalid, keeping current version"
      rm -f "$tmp_file"
    fi
  else
    log ERROR "Failed to download update from GitHub"
    rm -f "$tmp_file"
  fi

  return 0
}

# --- PRE-FLIGHT CHECKS ---
if [[ $EUID -ne 0 ]]; then echo "❌ Error: Must run as root (Try using 'sudo')" >&2; log ERROR "Must run as root (Try using 'sudo')"; exit 1; fi
command -v apt-get &>/dev/null || { echo "❌ Error: apt-get not found" >&2; log ERROR "apt-get not found"; exit 1; }

# Handle --update flag: update script from GitHub and exit (no main execution)
if [[ "${1:-}" == "--update" ]]; then
  auto_update "yes"
  echo "$(basename "${BASH_SOURCE[0]}") is already up to date ($SCRIPT_VERSION)." >&2
  exit 0
fi

auto_update "$@"

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
apt_log=$(mktemp "/tmp/apt-upgrade.XXXXXX")
trap 'rm -f "$apt_log"' EXIT
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" 2>&1 | tee "$apt_log" | grep -E '^(Get|Setting|Processing|done|Unpacking|Setting|upgraded|removed|newly installed|Preparing|^$)' >&2
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
REPORT+="✅ *$PACKAGE_COUNT packages installed:*"$'\n'
for pkg in $UPGRADE_LIST; do 
  REPORT+="• $pkg"$'\n'
done

REBOOT_NOTE=""
if $KERNEL_UPDATED && [[ -n "$REBOOT_REQ" ]]; then
  REBOOT_NOTE="⚠️ Kernel updated — reboot required"
elif $KERNEL_UPDATED && [[ -z "$REBOOT_REQ" ]]; then
  REBOOT_NOTE="⚠️ Kernel updated — reboot might be required"
elif ! $KERNEL_UPDATED && [[ -n "$REBOOT_REQ" ]]; then
  REBOOT_NOTE="⚠️ Reboot still required (kernel previously updated)"
else
  REBOOT_NOTE="✅ No kernel update"
fi
REPORT+=$'\n'"$REBOOT_NOTE"

log INFO "Upgrade completed"
echo "  📧 Sending Telegram notification..." >&2

send_telegram "$REPORT"
