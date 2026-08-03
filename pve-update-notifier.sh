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

SCRIPT_VERSION="v0.5.12"

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
    # 🛡️ Sentinel Security Fix: Prevent command option injection in logger
    logger -t "pve-update-notifier" -p "user.${level,,}" -- "$*" 2>/dev/null || true
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

# 🛡️ Sentinel Security Fix: Escape Markdown control characters to prevent Telegram API injection DoS
HOSTNAME="${HOSTNAME//_/\\_}"
HOSTNAME="${HOSTNAME//\*/\\*}"
HOSTNAME="${HOSTNAME//\[/\\[}"
HOSTNAME="${HOSTNAME//\]/\\]}"
HOSTNAME="${HOSTNAME//\`/\\\`}"

AUTO_UPDATE="${AUTO_UPDATE:-no}" # Set to "yes" to enable automatic script updates from GitHub

# --- TELEGRAM FUNCTION ---
send_telegram() {
    local message="$1"
    [[ -z "${TOKEN}" || -z "${CHAT_ID}" ]] && { log WARN "⏭️ Telegram config missing, skipping notification. Please set TOKEN and CHAT_ID in telegram.conf or /etc/pve-telegram.conf"; return 0; }

    local URL="https://api.telegram.org/bot${TOKEN}/sendMessage"

    # 🛡️ Sentinel Security Fix: Prevent TOKEN leakage and fix ARG_MAX for large reports.
    # Use process substitution for config and pass the message body via stdin.
    RESPONSE=$(curl -s -X POST -K <(cat <<CURL_CONF
url = "$URL"
data-urlencode = "chat_id=$CHAT_ID"
data-urlencode = "parse_mode=Markdown"
CURL_CONF
) --data-urlencode "text@-" <<< "$message")

    if [[ $RESPONSE != *'"ok":true'* ]]; then
        log ERROR "❌ Telegram Error: $RESPONSE (Check bot token or network)"
    else
        log INFO "✅ Telegram delivery successful."
    fi
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
    log INFO "⚠️ Could not determine latest version from GitHub (or GitHub not reachable), proceeding with current version ($SCRIPT_VERSION)"
    return 0
  fi

  if [[ ! "$latest_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log ERROR "❌ Invalid version tag format received from GitHub: $latest_tag (Expected vX.Y.Z)"
    return 0
  fi

  if [[ "$latest_tag" == "$SCRIPT_VERSION" ]]; then
    log INFO "✅ Script is up to date ($SCRIPT_VERSION)"
    return 0
  fi

  if version_compare "$latest_tag" "$SCRIPT_VERSION"; then
    log INFO "✅ Script is up to date ($SCRIPT_VERSION >= $latest_tag)"
    return 0
  fi

  local script_name
  script_name="$(basename "${BASH_SOURCE[0]}")"

  log INFO "⚠️ New version available: $latest_tag (current: $SCRIPT_VERSION)"

  if [[ "$force" == "no" && "$auto_update_enabled" == "no" ]]; then
    log INFO "ℹ️ Auto-update is disabled. Sending update available notification..."
    send_telegram "⚠️ *Script Update Available*

📜 \`${script_name}\`
📌 Current: \`${SCRIPT_VERSION}\`
🆕 Latest: \`${latest_tag}\`

Run \`bash ${script_name} --update\` to install."
    return 0
  fi

  log INFO "ℹ️ Downloading update..."

  local tmp_file
  tmp_file=$(mktemp "/tmp/${script_name}.XXXXXX") || return 1

  if curl -sL --connect-timeout 5 --max-time 30 \
    -o "$tmp_file" \
    "https://raw.githubusercontent.com/spupuz/proxmox-scripts/${latest_tag}/${script_name}"; then

    if head -1 "$tmp_file" | grep -q '^#!'; then
      rm -f "${BASH_SOURCE[0]}.bak" # 🛡️ Sentinel Security Fix: Prevent symlink attack via cp
      cp "${BASH_SOURCE[0]}" "${BASH_SOURCE[0]}.bak"
      mv "$tmp_file" "${BASH_SOURCE[0]}"
      chmod +x "${BASH_SOURCE[0]}"
      log INFO "✅ Script updated to $latest_tag"
      send_telegram "✅ *Script Updated*

📜 \`${script_name}\`
📌 \`${SCRIPT_VERSION}\` → 🆕 \`${latest_tag}\`"
      if [[ "${force}" == "yes" ]]; then
        log INFO "✅ Updated to $latest_tag"
        exec "${BASH_SOURCE[0]}"
      fi
      log INFO "ℹ️ Re-executing..."
      exec "${BASH_SOURCE[0]}" "$@"
    else
      log ERROR "❌ Downloaded file appears invalid, keeping current version (Check GitHub status)"
      rm -f "$tmp_file"
    fi
  else
    log ERROR "❌ Failed to download update from GitHub (Check network connectivity)"
    rm -f "$tmp_file"
  fi

  return 0
}

# --- PRE-FLIGHT CHECKS ---
if [[ $EUID -ne 0 ]]; then
    log ERROR "❌ Error: This script must be run as root (Try using 'sudo')."
    exit 1
fi

# Detect if running on a Proxmox VE host
IS_PVE_HOST=false
if command -v pct >/dev/null 2>&1; then
    IS_PVE_HOST=true
else
    log INFO "⏭️ pct command not found, skipping LXC container checks"
fi

# Handle --update flag: update script from GitHub and exit (no main execution)
if [[ "${1:-}" == "--update" ]]; then
  auto_update "yes"
  log INFO "✅ $(basename "${BASH_SOURCE[0]}") is already up to date ($SCRIPT_VERSION)."
  exit 0
fi

auto_update "$@"

log INFO "ℹ️ Starting update check for $HOSTNAME..."

# Initialize the report message with clear line breaks
REPORT="*🔔 Update Report: $HOSTNAME*"$'\n\n'

# 1. CHECK PROXMOX HOST
log INFO "ℹ️ Checking Proxmox Host..."
if apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 > /dev/null 2>&1; then
    HOST_UPDATES=$(apt-get -s upgrade | grep -P '^\d+ upgraded' | cut -d' ' -f1)

    # Sanitize to prevent command injection
    HOST_UPDATES_CLEAN="${HOST_UPDATES//[^0-9]/}"

    if [ -z "$HOST_UPDATES_CLEAN" ] || [ "$HOST_UPDATES_CLEAN" -eq 0 ]; then
        REPORT+="🖥️ *Proxmox Host*: ✅ Up to date"$'\n'
    else
        REPORT+="🖥️ *Proxmox Host*: ⚠️ $HOST_UPDATES_CLEAN updates available"$'\n'
    fi
else
    REPORT+="🖥️ *Proxmox Host*: ❌ Error during check (Check network or apt locks)"$'\n'
fi

if $IS_PVE_HOST; then
  REPORT+=$'\n'"*📦 Running LXC Containers:*"$'\n'

  # 2. CHECK ALL RUNNING LXC CONTAINERS
  lxc_list=()
  mapfile -t lxc_list < <(pct list | awk 'NR>1 && $2=="running" {print $1 ":" $NF}')

  if [ ${#lxc_list[@]} -eq 0 ]; then
      REPORT+="• ⏭️ No running containers found"$'\n'
  else
      # ⚡ Bolt: Use a temporary directory to store bounded concurrent execution results
      TMP_DIR=$(mktemp -d "/tmp/pve-update-notifier.XXXXXX")
      MAX_JOBS=5

      for item in "${lxc_list[@]}"; do
          [[ -z "$item" ]] && continue
          CTID="${item%%:*}"
          CTNAME="${item##*:}"
          # 🛡️ Sentinel Security Fix: Escape container name to prevent Markdown injection
          CTNAME="${CTNAME//_/\\_}"
          CTNAME="${CTNAME//\*/\\*}"
          CTNAME="${CTNAME//\[/\\[}"
          CTNAME="${CTNAME//\]/\\]}"
          CTNAME="${CTNAME//\`/\\\`}"
          log INFO "ℹ️ Checking LXC $CTID ($CTNAME)..."

          # ⚡ Bolt: Execute container checks concurrently in the background
          (
              LXC_UPD_RESULT=$(timeout 60 pct exec "$CTID" -- bash -c '
                  if ! command -v apt-get > /dev/null 2>&1; then
                      echo "NO_APT"
                      exit 0
                  fi
                  # We use a host-level timeout and apt timeouts to prevent hung processes if container networking is down
                  if apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 > /dev/null 2>&1; then
                      apt-get -s upgrade 2>/dev/null | grep -P "^\d+ upgraded" | cut -d" " -f1 || echo "0"
                  else
                      echo "ERROR"
                  fi
              ' || echo "ERROR")

              # Sanitize to prevent command injection
              LXC_UPD_RESULT_CLEAN="${LXC_UPD_RESULT//[^0-9]/}"

              # Save the formatted result line to a temporary file
              if [ "$LXC_UPD_RESULT" = "NO_APT" ]; then
                  echo "• ID $CTID ($CTNAME): ⏭️ No APT found" > "$TMP_DIR/$CTID"
              elif [ "$LXC_UPD_RESULT" = "ERROR" ]; then
                  echo "• ID $CTID ($CTNAME): ❌ Error checking updates (Container offline or timed out)" > "$TMP_DIR/$CTID"
               elif [ ! -z "$LXC_UPD_RESULT_CLEAN" ] && [ "$LXC_UPD_RESULT_CLEAN" -gt 0 ] 2>/dev/null; then
                  echo "• ID $CTID ($CTNAME): ⚠️ *$LXC_UPD_RESULT_CLEAN* updates available" > "$TMP_DIR/$CTID"
              else
                  echo "• ID $CTID ($CTNAME): ✅ Up to date" > "$TMP_DIR/$CTID"
              fi
          ) &

          # ⚡ Bolt: Bound concurrency to prevent I/O thrashing
          while (( $(jobs -r -p | wc -l) >= MAX_JOBS )); do
              sleep 0.5
          done
      done

      # Wait for all background checks to finish
      wait

      # Read the results in the original order
      for item in "${lxc_list[@]}"; do
          [[ -z "$item" ]] && continue
          CTID="${item%%:*}"
          if [ -f "$TMP_DIR/$CTID" ]; then
              REPORT+="$(cat "$TMP_DIR/$CTID")"$'\n'
          fi
      done

      rm -rf "$TMP_DIR"
  fi
else
  log INFO "⏭️ Not a PVE host, skipping LXC container checks"
fi

# 3. SEND NOTIFICATION
log INFO "ℹ️ Sending report to Telegram..."
send_telegram "$REPORT"