#!/usr/bin/env bash
#
# Proxmox LXC Auto-Updater with Telegram Notifications
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
# 
# Features:
# - Reports available Proxmox Host updates (check-only)
# - Updates all running LXC containers
#   1. Runs internal update scripts (e.g., from tteck helper scripts)
#   2. Performs OS package updates (apt, apk, dnf, yum)
# - Exclude specific containers via EXCLUDED_CTIDS
# - Telegram notification with detailed results

set -Eeuo pipefail

SCRIPT_VERSION="v0.5.0"

# --- CONFIGURATION ---
TOKEN=""
CHAT_ID=""
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
EXCLUDED_CTIDS=() # Example: ("100" "101")
CLEAN_TMP_7_DAYS="yes" # Set to "yes" to delete files/directories in container's /tmp older than 7 days
CT_OPERATION_TIMEOUT=300 # Seconds before timing out operations inside containers (default: 5 minutes)
AUTO_UPDATE="no" # Set to "yes" to enable automatic script updates from GitHub.
# WARNING: Enabling auto-update on a compromised repository is dangerous.
# Use --update flag to manually update when needed.

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
EXCLUDED_CTIDS=("${EXCLUDED_CTIDS[@]:-}")
CLEAN_TMP_7_DAYS="${CLEAN_TMP_7_DAYS:-yes}"
CT_OPERATION_TIMEOUT="${CT_OPERATION_TIMEOUT:-300}"
AUTO_UPDATE="${AUTO_UPDATE:-no}"

# Update scripts to attempt inside every container, in order
UPDATE_CANDIDATES=(
  "/usr/local/bin/update"
  "/usr/local/sbin/update"
  "/usr/bin/update"
  "update"
  "/root/update.sh"
)

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
    logger -t "lxc-updater" -p "user.${level,,}" "$*" 2>/dev/null || true
  fi
}

# --- HELPER FUNCTIONS ---

send_telegram() {
    local message="$1"
    [[ -z "${TOKEN}" || -z "${CHAT_ID}" ]] && { log WARN "Telegram config missing, skipping notification. Please set TOKEN and CHAT_ID in telegram.conf or /etc/pve-telegram.conf"; return 0; }

    log INFO "Sending report to Telegram..."
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
  latest_tag=$(curl -s --connect-timeout 5 --max-time 10 \
    "https://api.github.com/repos/spupuz/proxmox-scripts/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')

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
    send_telegram "🔄 *Script Update Available*

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
        return 0
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

run_in_ct() {
  local ctid="$1"
  shift
  timeout "${CT_OPERATION_TIMEOUT:-300}" pct exec "$ctid" -- bash -c "$*" < /dev/null
}

is_excluded() {
  local ctid="$1"
  for excluded in "${EXCLUDED_CTIDS[@]}"; do
    [[ "$ctid" == "$excluded" ]] && return 0
  done
  return 1
}

# --- UPDATE LOGIC ---

check_host_updates() {
   log INFO "Checking Proxmox Host for updates..."
   # Optimize connection timeout to avoid hanging if host repositories are down
   apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 > /dev/null 2>&1 || return 1
   HOST_UPDATES=$(apt-get -s upgrade | grep -P '^\d+ upgraded' | cut -d' ' -f1 || echo "0")
   echo "${HOST_UPDATES:-0}"
 }

update_lxc() {
  local ctid="$1"
  local ctname="$2"
  local app_updated="no"
  local pkg_updated="no"
  local error_msg=""

  log INFO "Processing LXC $ctid ($ctname)..."

  # Batched Environment Detection
  # Prevents severe O(N) latency caused by repeatedly spawning Proxmox CLI ('pct exec')
  local candidates_str="${UPDATE_CANDIDATES[*]}"
  local env_script=$(cat << EOF
APP_CMD=""
PKG_MGR=""
HAS_NETBIRD="no"

for c in $candidates_str; do
  if command -v "\$c" >/dev/null 2>&1 || [ -x "\$c" ]; then
    APP_CMD="\$c"
    break
  fi
done

if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
fi

if command -v netbird >/dev/null 2>&1; then HAS_NETBIRD="yes"; fi

echo "APP_CMD=\$APP_CMD"
echo "PKG_MGR=\$PKG_MGR"
echo "HAS_NETBIRD=\$HAS_NETBIRD"
EOF
  )

  local env_out
  env_out=$(run_in_ct "$ctid" "$env_script" 2>/dev/null || true)

  local app_cmd
  app_cmd=$(echo "$env_out" | grep '^APP_CMD=' | cut -d'=' -f2-)
  local pkg_mgr
  pkg_mgr=$(echo "$env_out" | grep '^PKG_MGR=' | cut -d'=' -f2-)
  local has_netbird
  has_netbird=$(echo "$env_out" | grep '^HAS_NETBIRD=' | cut -d'=' -f2-)

  # 1. ATTEMPT APP UPDATE (Custom/Helper Scripts)
  if [[ -n "$app_cmd" ]]; then
    log DEBUG "  -> Found app update script: $app_cmd. Attempting unattended verbose execution..."
    echo "    🔄 Running app update via $app_cmd..." >&2
    # Create dummy 'clear' and 'whiptail' commands to bypass interactive menus and preventing crashes
    # Whiptail dummy will always echo '2' (Verbose Mode) as its answer
    # We use a secure temporary directory to prevent privilege escalation via predictable /tmp path
    if run_in_ct "$ctid" "tmp_bin=\$(mktemp -d /tmp/bin.XXXXXX) || exit 1; trap 'rm -rf \"\$tmp_bin\"' EXIT; printf '#!/bin/sh\nexit 0' > \"\$tmp_bin/clear\"; printf '#!/bin/sh\necho 2; exit 0' > \"\$tmp_bin/whiptail\"; chmod +x \"\$tmp_bin/clear\" \"\$tmp_bin/whiptail\"; export PATH=\"\$tmp_bin:\$PATH\"; export TERM=dumb; export DEBIAN_FRONTEND=noninteractive; export RD=1; export verbose=1; export var_verbose=yes; export var_unattended=yes; $app_cmd" >&2; then
      app_updated="yes"
      log INFO "  -> App update completed successfully"
    else
      error_msg="App update script ($app_cmd) failed."
      log WARN "  -> App update failed"
    fi
  fi

  # 2. SYSTEM PACKAGE UPDATE (Fallback/Complementary)
  if [[ "$pkg_mgr" == "apt-get" ]]; then
    # Correct syntax for passing dpkg options through apt-get, adding connection timeouts, and a sleep for APT locks
    if run_in_ct "$ctid" "sleep 2; export DEBIAN_FRONTEND=noninteractive; apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1; apt-get dist-upgrade -y -o Dpkg::Options::=\"--force-confold\" -o Dpkg::Options::=\"--force-confdef\" && apt-get autoremove -y && apt-get clean" >&2; then
      pkg_updated="yes"
    else
      error_msg="${error_msg:+$error_msg; }APT update failed"
    fi
  elif [[ "$pkg_mgr" == "apk" ]]; then
    if run_in_ct "$ctid" "apk update && apk upgrade" >&2; then
      pkg_updated="yes"
    else
      error_msg="${error_msg:+$error_msg; }APK update failed"
    fi
  elif [[ "$pkg_mgr" == "dnf" ]]; then
    if run_in_ct "$ctid" "dnf -y upgrade --refresh" >&2; then
      pkg_updated="yes"
    else
      error_msg="${error_msg:+$error_msg; }DNF update failed"
    fi
  elif [[ "$pkg_mgr" == "yum" ]]; then
    if run_in_ct "$ctid" "yum -y update" >&2; then
      pkg_updated="yes"
    else
      error_msg="${error_msg:+$error_msg; }YUM update failed"
    fi
  fi

  # 3. NETBIRD SPECIAL CHECK
  local netbird_info=""
  if [[ "$has_netbird" == "yes" ]]; then
    log DEBUG "  -> NetBird detected. Checking connection status..."
    # ⚡ Bolt: Batched NetBird execution
    # Impact: Reduces Proxmox CLI ('pct exec') calls from up to 3 down to 1
    # by handling the disconnected state recovery entirely inside the container.
    local nb_script=$(cat << 'EOF'
status=$(netbird status 2>/dev/null || echo "Error getting status")
if [[ "$status" == *"Management: Disconnected"* ]]; then
  echo "DISCONNECTED" >&2
  netbird up >/dev/null 2>&1 || true
  status=$(netbird status 2>/dev/null || echo "Error getting status")
fi
echo "$status"
EOF
    )
    
    local nb_status
    nb_status=$(run_in_ct "$ctid" "$nb_script" 2> >(
      while read -r line; do
        if [[ "$line" == "DISCONNECTED" ]]; then
          echo "  -> NetBird disconnected! Attempting to bring it up..." >&2
        fi
      done
    ) || true)
    
    local nb_ip
    nb_ip=$(echo "$nb_status" | grep 'NetBird IP:' | awk '{print $NF}' | tr -d '\r' || echo "N/A")
    if [[ -z "$nb_ip" || "$nb_ip" == "N/A" ]]; then
      netbird_info="      ⚠️ NetBird: Disconnected"
    else
      netbird_info="      🌐 NetBird IP: $nb_ip"
    fi
  fi

  # 4. OPTIONAL /tmp CLEANUP (older than 7 days)
  if [[ "${CLEAN_TMP_7_DAYS}" == "yes" ]]; then
    log DEBUG "  -> Cleaning up files in container's /tmp older than 7 days..."
    # We use find with -mindepth 1 to avoid deleting the /tmp directory itself
    run_in_ct "$ctid" "find /tmp -mindepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true" >/dev/null 2>&1 || true
  fi

  # Formatting result for report
  local final_line=""
  if [[ "$app_updated" == "yes" && "$pkg_updated" == "yes" ]]; then
    final_line="• $ctid ($ctname): ✅ App + OS Updated"
  elif [[ "$app_updated" == "yes" ]]; then
    final_line="• $ctid ($ctname): ⚠️ App Updated (OS update skipped/failed)"
  elif [[ "$pkg_updated" == "yes" ]]; then
    final_line="• $ctid ($ctname): ✅ OS Updated (No app script found)"
  else
    final_line="• $ctid ($ctname): ❌ Update failed: ${error_msg:-No method found}"
  fi

  echo "$final_line"
  if [[ -n "$netbird_info" ]]; then
    echo "$netbird_info"
  fi
  log DEBUG "update_lxc finished for $ctid ($ctname)"
  return 0
}

# --- MAIN ---

main() {
  # --- PRE-FLIGHT CHECKS ---
  if [[ $EUID -ne 0 ]]; then
      echo "❌ Error: This script must be run as root (Try using 'sudo')." >&2
      exit 1
  fi

  if ! command -v pct >/dev/null 2>&1; then
      echo "❌ Error: Proxmox Virtual Environment commands (pct) not found. Are you running this on a PVE host?" >&2
      exit 1
  fi

  auto_update "$@"

  local ok_count=0
  local fail_count=0
  local skip_count=0
  local report=""

  report+="*🔄 Proxmox Auto-Update Report: ${HOSTNAME}*"$'\n\n'

  # 1. CHECK HOST
  local host_upd
  host_upd=$(check_host_updates || echo "error")

  # Sanitize to prevent command injection in arithmetic context
  local host_upd_clean="${host_upd//[^0-9]/}"

  if [[ "$host_upd" == "error" ]]; then
    report+="🖥️ *Proxmox Host*: ❌ Error during check"$'\n'
  elif [[ -n "$host_upd_clean" ]] && [[ "$host_upd_clean" -gt 0 ]]; then
    report+="🖥️ *Proxmox Host*: ⚠️ $host_upd updates available (not installed)"$'\n'
  else
    report+="🖥️ *Proxmox Host*: ✅ System is up to date"$'\n'
  fi

  report+=$'\n'"*📦 LXC Containers Status:*"$'\n'

  # 2. GET RUNNING LXCS
  local lxc_list=()
  mapfile -t lxc_list < <(pct list | awk 'NR>1 && $2=="running" {print $1 ":" $NF}')

  log DEBUG "Detected ${#lxc_list[@]} running containers: ${lxc_list[*]:-none}"

  if [[ ${#lxc_list[@]} -eq 0 ]]; then
    report+="• No running containers found."$'\n'
  else
    # Disable immediate exit to ensure the loop continues for all containers
    set +e
    
    for item in "${lxc_list[@]}"; do
      [[ -z "$item" ]] && continue

      local ctid="${item%%:*}"
      local ctname="${item##*:}"

      if is_excluded "$ctid"; then
        report+="• ${ctid}: ⏭️ Excluded"$'\n'
        ((skip_count++))
        continue
      fi

      log DEBUG "Starting update for container $ctid ($ctname)"
      local result
      result=$(update_lxc "$ctid" "$ctname")

      report+="$result"$'\n'
      log DEBUG "Completed container $ctid"

      if [[ "$result" == *"✅"* ]]; then ((ok_count++))
      elif [[ "$result" == *"⚠️"* ]]; then ((ok_count++))
      elif [[ "$result" == *"❌"* ]]; then ((fail_count++))
      else ((skip_count++)); fi
    done
    
    # Re-enable immediate exit
    set -e
    log DEBUG "Finished processing all running containers"
  fi

  report+=$'\n'
  report+="✅ Updated: ${ok_count}"$'\n'
  report+="⏭️ Excluded: ${skip_count}"$'\n'
  report+="❌ Failed: ${fail_count}"$'\n'

  send_telegram "$report"
}

# --- ENTRY POINT ---
# Handle --update flag: update script from GitHub and exit (no main execution)
if [[ "${1:-}" == "--update" ]]; then
  auto_update "yes"
  echo "$(basename "${BASH_SOURCE[0]}") is already up to date ($SCRIPT_VERSION)." >&2
  exit 0
fi

main "$@"