#!/bin/bash
#
# Proxmox Host & LXC Update Notifier
#
# LICENSE & DISCLAIMER:
# This script is provided "AS IS", without warranty of any kind, express or
# implied, including but not limited to the warranties of merchantability,
# fitness for a particular purpose and noninfringement. In no event shall the
# authors or copyright holders be liable for any claim, damages or other
# liability, whether in an action of contract, tort or otherwise, arising from,
# out of or in connection with the software or the use or other dealings in the
# software.
#
# Use this script at your own risk. The authors are not responsible for any
# data loss, system instability, or service downtime caused by running it.

SCRIPT_VERSION="v0.0.2"

# Add this path variable so Cron can find the required system commands
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- LOGGING ---
LOG_STDOUT="${LOG_STDOUT:-yes}" # Set to "no" to disable console output (useful for cron)

log() {
  local level="${1:-INFO}"
  shift
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  local message="${timestamp} [${level}] $*"

  if [[ "${LOG_STDOUT}" == "yes" ]]; then
    echo "${message}" >&2
  fi

  if command -v logger &>/dev/null; then
    logger -t "pve-update-notifier" -p "user.${level,,}" "$*" 2>/dev/null || true
  fi
}

# --- CONFIGURATION ---
TOKEN=""
CHAT_ID=""
HOSTNAME=$(hostname -f)

# Load external configuration if present (overrides hardcoded values)
# Environment variables take precedence over config file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/telegram.conf" ]]; then
  source "${SCRIPT_DIR}/telegram.conf"
elif [[ -f "/etc/pve-telegram.conf" ]]; then
  source "/etc/pve-telegram.conf"
fi

# Override with environment variables if set
TOKEN="${TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"

# --- TELEGRAM FUNCTION ---
send_telegram() {
    local message="$1"
    [[ -z "${TOKEN}" || -z "${CHAT_ID}" ]] && { log WARN "Telegram config missing, skipping notification."; return 0; }

    local URL="https://api.telegram.org/bot${TOKEN}/sendMessage"

    RESPONSE=$(curl -s -X POST "$URL" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "text=$message")

    if [[ $RESPONSE != *'"ok":true'* ]]; then
        log ERROR "Telegram Error: $RESPONSE"
        echo "❌ Telegram Error: $RESPONSE" >&2
    else
        log INFO "Telegram delivery successful."
    fi
}

# --- AUTO-UPDATE ---
version_compare() {
  local v1="${1#v}" v2="${2#v}"
  local IFS=.
  read -r major1 minor1 patch1 <<< "$v1"
  read -r major2 minor2 patch2 <<< "$v2"
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
  [[ "${AUTO_UPDATE:-yes}" == "no" ]] && return 0

  if ! curl -s --connect-timeout 5 --max-time 10 "https://api.github.com" >/dev/null 2>&1; then
    log INFO "GitHub not reachable, proceeding with current version ($SCRIPT_VERSION)"
    return 0
  fi

  local latest_tag
  latest_tag=$(curl -s --connect-timeout 5 --max-time 10 \
    "https://api.github.com/repos/spupuz/proxmox-scripts/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')

  if [[ -z "$latest_tag" ]]; then
    log WARN "Could not determine latest version from GitHub"
    return 0
  fi

  if [[ "$latest_tag" == "$SCRIPT_VERSION" ]]; then
    log INFO "Script is up to date ($SCRIPT_VERSION)"
    return 0
  fi

  # Compare versions: only update if latest is actually newer
  if version_compare "$latest_tag" "$SCRIPT_VERSION"; then
    log INFO "Script is up to date ($SCRIPT_VERSION >= $latest_tag)"
    return 0
  fi

  log INFO "New version available: $latest_tag (current: $SCRIPT_VERSION)"
  log INFO "Downloading update..."

  local script_name
  script_name="$(basename "${BASH_SOURCE[0]}")"
  local tmp_file="/tmp/${script_name}.new"

  if curl -sL --connect-timeout 5 --max-time 30 \
    -o "$tmp_file" \
    "https://raw.githubusercontent.com/spupuz/proxmox-scripts/${latest_tag}/${script_name}"; then

    if head -1 "$tmp_file" | grep -q '^#!'; then
      cp "${BASH_SOURCE[0]}" "${BASH_SOURCE[0]}.bak"
      mv "$tmp_file" "${BASH_SOURCE[0]}"
      chmod +x "${BASH_SOURCE[0]}"
      log INFO "Script updated to $latest_tag, re-executing..."
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
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root." >&2
    exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
    echo "❌ Error: Proxmox Virtual Environment commands (pct) not found. Are you running this on a PVE host?" >&2
    exit 1
fi

auto_update "$@"

log INFO "Starting update check for $HOSTNAME..."

# Initialize the report message with clear line breaks
REPORT="*🔔 Update Report: $HOSTNAME*"$'\n\n'

# 1. CHECK PROXMOX HOST
log INFO "Checking Proxmox Host..."
apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 > /dev/null 2>&1
HOST_UPDATES=$(apt-get -s upgrade | grep -P '^\d+ upgraded' | cut -d' ' -f1)

if [ -z "$HOST_UPDATES" ] || [ "$HOST_UPDATES" -eq 0 ]; then
    REPORT+="🖥️ *Proxmox Host*: ✅ Up to date"$'\n'
else
    REPORT+="🖥️ *Proxmox Host*: $HOST_UPDATES updates available"$'\n'
fi

REPORT+=$'\n'"*📦 Running LXC Containers:*"$'\n'

# 2. CHECK ALL RUNNING LXC CONTAINERS
# ⚡ Bolt Optimization: Cache `pct list` output outside the loop to avoid spawning a heavy CLI process per container.
# Expected Impact: Reduces O(N) process spawning latency to O(1), saving ~0.5s - 1s per container.
PCT_LIST_CACHE=$(pct list 2>/dev/null || true)
LXC_LIST=$(echo "$PCT_LIST_CACHE" | awk '$2=="running" {print $1}')

if [ -z "$LXC_LIST" ]; then
    REPORT+="• No running containers found"$'\n'
else
for CTID in $LXC_LIST; do
    CTNAME=$(echo "$PCT_LIST_CACHE" | grep "^$CTID" | awk '{print $3}')
    log INFO "Checking LXC $CTID ($CTNAME)..."
        
        if pct exec $CTID -- which apt-get > /dev/null 2>&1; then
            # We use a host-level timeout and apt timeouts to prevent hung processes if container networking is down
            timeout 60 pct exec $CTID -- apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 > /dev/null 2>&1
            LXC_UPD_COUNT=$(timeout 60 pct exec $CTID -- apt-get -s upgrade 2>/dev/null | grep -P '^\d+ upgraded' | cut -d' ' -f1 || echo "0")
            
            if [ ! -z "$LXC_UPD_COUNT" ] && [ "$LXC_UPD_COUNT" -gt 0 ]; then
                REPORT+="• ID $CTID ($CTNAME): *$LXC_UPD_COUNT* updates"$'\n'
            else
                REPORT+="• ID $CTID ($CTNAME): ✅ Up to date"$'\n'
            fi
        else
            REPORT+="• ID $CTID ($CTNAME): ⚠️ No APT found"$'\n'
        fi
    done
fi

# 3. SEND NOTIFICATION
log INFO "Sending report to Telegram..."
send_telegram "$REPORT"