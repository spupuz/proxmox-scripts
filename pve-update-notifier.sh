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

SCRIPT_VERSION="v0.7.0"

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
CHECK_DISK_USAGE="yes" # Set to "yes" to report the local disk usage (internal volumes only, excludes bind mounts) of each LXC
DISK_USAGE_THRESHOLD=75 # Percentage threshold above which an LXC disk alarm is raised (e.g. 75)

secure_source() {
  local conf_file="$1"
  if [[ ! -f "$conf_file" ]]; then return 0; fi
  if [[ -h "$conf_file" ]]; then
    log ERROR "❌ SECURITY CRITICAL: $conf_file is a symlink. Refusing to load to prevent privilege escalation."
    return 1
  fi

  local stat_out perms owner
  stat_out=$(stat -c "%a %U" "$conf_file" 2>/dev/null || echo "777 root")
  perms="${stat_out%% *}"
  owner="${stat_out#* }"

  if [[ "$perms" != "600" ]] || [[ "$owner" != "root" ]]; then
    log WARN "⚠️ SECURITY WARNING: Config file $conf_file has insecure permissions/ownership ($perms $owner)."
    log INFO "ℹ️ Attempting to secure it to 600 root..."
    if chown root:root "$conf_file" 2>/dev/null && chmod 600 "$conf_file" 2>/dev/null; then
      log INFO "✅ Successfully secured $conf_file permissions."
    else
      log ERROR "❌ SECURITY CRITICAL: Cannot secure $conf_file. Refusing to load it to prevent arbitrary code execution. (Check file owner/permissions manually)"
      return 1
    fi
  fi
  source "$conf_file"
}

# Load external configuration if present (overrides hardcoded values)
# Environment variables take precedence over config file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/telegram.conf" ]]; then
  secure_source "${SCRIPT_DIR}/telegram.conf"
elif [[ -f "/etc/pve-telegram.conf" ]]; then
  secure_source "/etc/pve-telegram.conf"
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

CHECK_DISK_USAGE="${CHECK_DISK_USAGE:-yes}"
DISK_USAGE_THRESHOLD="${DISK_USAGE_THRESHOLD:-75}"
DISK_USAGE_THRESHOLD="${DISK_USAGE_THRESHOLD//[^0-9]/}"
DISK_USAGE_THRESHOLD="${DISK_USAGE_THRESHOLD:-75}"

# --- TELEGRAM FUNCTION ---
send_telegram() {
    local message="$1"
    [[ -z "${TOKEN}" || -z "${CHAT_ID}" ]] && { log INFO "⏭️ Telegram config missing, skipping notification. Please set TOKEN and CHAT_ID in telegram.conf or /etc/pve-telegram.conf"; return 0; }

    local URL="https://api.telegram.org/bot${TOKEN}/sendMessage"

    # 🛡️ Sentinel Security Fix: Prevent TOKEN leakage and fix ARG_MAX for large reports.
    # Use process substitution for config and pass the message body via stdin.
    RESPONSE=$(curl --proto '=https' --tlsv1.2 -s --connect-timeout 10 --max-time 30 -X POST -K <(cat <<CURL_CONF
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

# All scripts share the same version and are released together, so updating any
# one of them also updates the other scripts installed in the same directory.
ALL_SCRIPT_NAMES=("lxc-updater.sh" "pve-update-notifier.sh" "system-update-notifier.sh")

auto_update() {
  local force="${1:-no}"
  local auto_update_enabled="${AUTO_UPDATE:-no}"

  local latest_tag=""
  # ⚡ Bolt: Store headers and use pure Bash regex to extract version tag
  # Impact: Prevents spawning 3 external processes (grep, sed, tr) per auto-update check (~40x faster)
  local header
  header=$(curl --proto '=https' --tlsv1.2 -sI --connect-timeout 5 --max-time 10 \
    "https://github.com/spupuz/proxmox-scripts/releases/latest" 2>/dev/null || true)

  if [[ "$header" =~ (^|[[:space:]])[Ll]ocation:[[:space:]]*.*/tag/([^[:space:]]+) ]]; then
    latest_tag="${BASH_REMATCH[2]%$'\r'}"
  fi

  if [[ -z "$latest_tag" ]]; then
    log WARN "⚠️ Could not determine latest version from GitHub (or GitHub not reachable), proceeding with current version ($SCRIPT_VERSION)"
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

  # Never downgrade: version_compare returns 0 (equal), 1 (v1 > v2) or 2 (v1 < v2).
  # Only when current < latest (rc=2) should we proceed with the download.
  # The `|| local` keeps the non-zero return from tripping `set -e`.
  local vc_rc=0
  version_compare "$SCRIPT_VERSION" "$latest_tag" || local vc_rc=$?
  if [[ "$vc_rc" -ne 2 ]]; then
    log INFO "✅ Script is up to date ($SCRIPT_VERSION >= $latest_tag)"
    return 0
  fi

  local script_name
  script_name="$(basename "${BASH_SOURCE[0]}")"

  log WARN "⚠️ New version available: $latest_tag (current: $SCRIPT_VERSION)"

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

  local repo_base="https://raw.githubusercontent.com/spupuz/proxmox-scripts/${latest_tag}"
  local updated_any="no"
  local updated_list=()

  for name in "${ALL_SCRIPT_NAMES[@]}"; do
    local target="${SCRIPT_DIR}/${name}"

    # Update scripts installed in this directory; always update the current one
    if [[ "$name" != "$script_name" && ! -f "$target" ]]; then
      log INFO "⏭️ Skipping $name (not installed in $SCRIPT_DIR)"
      continue
    fi

    local tmp_file
    tmp_file=$(mktemp "/tmp/${name}.XXXXXX") || { log ERROR "❌ Failed to create temporary file (Check /tmp permissions or disk space)"; continue; }

    if curl --proto '=https' --tlsv1.2 -sL --connect-timeout 5 --max-time 30 \
      -o "$tmp_file" "$repo_base/$name"; then

      if head -1 "$tmp_file" | grep -q '^#!'; then
        rm -f "${target}.bak" # 🛡️ Sentinel Security Fix: Prevent symlink attack via cp
        [[ -f "$target" ]] && cp "$target" "${target}.bak"
        mv "$tmp_file" "$target"
        chmod +x "$target"
        updated_any="yes"
        updated_list+=("$name")
        log INFO "✅ Updated $name to $latest_tag"
      else
        log ERROR "❌ Downloaded $name appears invalid, keeping current version (Check GitHub status)"
        rm -f "$tmp_file"
      fi
    else
      log ERROR "❌ Failed to download $name from GitHub (Check network connectivity)"
      rm -f "$tmp_file"
    fi
  done

  if [[ "$updated_any" == "yes" ]]; then
    local updated_msg=""
    for name in "${updated_list[@]}"; do
      updated_msg+="📜 \`${name}\`"$'\n'
    done
    send_telegram "✅ *Scripts Updated*

📌 \`${SCRIPT_VERSION}\` → 🆕 \`${latest_tag}\`

${updated_msg}"
    if [[ "${force}" == "yes" ]]; then
      log INFO "✅ Updated to $latest_tag"
      exec "${BASH_SOURCE[0]}"
    fi
    log INFO "ℹ️ Re-executing..."
    exec "${BASH_SOURCE[0]}" "$@"
  fi

  return 0
}

# --- DISK USAGE CHECK ---
# Report disk usage of an LXC's internal volumes only (rootfs + mpN entries that
# have a storage volume). Bind mounts (plain host paths) are excluded.
# Rootfs and each mountpoint are reported (and alarmed) separately, since a full
# rootfs can break the container even when other volumes have free space.
get_lxc_disk_summary() {
  local ctid="$1"
  local mp_list=()
  local line key vol mp df_out mp_out pct used size human_used human_size

  while IFS= read -r line; do
    key="${line%%:*}"
    if [[ "$key" == "rootfs" ]]; then
      mp_list+=("/")
      continue
    fi
    [[ "$key" == mp[0-9]* ]] || continue
    vol="${line#*: }"
    vol="${vol%%,*}"
    [[ "$vol" == *:* ]] || continue
    mp="${line#*,mp=}"
    mp="${mp%%,*}"
    [[ -n "$mp" ]] && mp_list+=("$mp")
  done < <(pct config "$ctid" 2>/dev/null)

  [[ ${#mp_list[@]} -eq 0 ]] && return 1

  df_out=$(timeout 30 pct exec "$ctid" -- df -Pk "${mp_list[@]}" 2>/dev/null) || return 1

  local lines=() label
  for mp in "${mp_list[@]}"; do
    mp_out="$(awk -v m="$mp" '$NF==m {print $3, $2, $5}' <<< "$df_out")"
    [[ -n "$mp_out" ]] || continue
    read -r used size pct <<< "$mp_out"
    pct="${pct%\%}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    human_used="$(awk -v u="$used" 'BEGIN {printf "%.1fG", u/1048576}')"
    human_size="$(awk -v s="$size" 'BEGIN {printf "%.1fG", s/1048576}')"
    if [[ "$mp" == "/" ]]; then
      label="Rootfs"
    else
      label="$mp"
    fi
    if (( pct >= DISK_USAGE_THRESHOLD )); then
      lines+=("      🚨 *${label}*: ${pct}% (>${DISK_USAGE_THRESHOLD}%) (${human_used}/${human_size})")
    else
      lines+=("      💾 ${label}: ${pct}% (${human_used}/${human_size})")
    fi
  done

  [[ ${#lines[@]} -eq 0 ]] && return 1

  printf '%s\n' "${lines[@]}"
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

# Handle --update flag: update scripts from GitHub, then continue with the main purpose
if [[ "${1:-}" == "--update" ]]; then
  auto_update "yes"
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
      TMP_DIR=$(mktemp -d "/tmp/pve-update-notifier.XXXXXX") || { log ERROR "❌ Failed to create temporary directory for concurrent execution (Check /tmp permissions or disk space)"; exit 1; }
      trap 'rm -rf "$TMP_DIR"' EXIT
      MAX_JOBS=5
      running_jobs=0

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

              # Optional: check local disk usage of internal volumes only
              DISK_MSG=""
              if [[ "${CHECK_DISK_USAGE}" == "yes" ]]; then
                  DISK_MSG=$(get_lxc_disk_summary "$CTID" || true)
              fi

              # Build the formatted result line
              if [ "$LXC_UPD_RESULT" = "NO_APT" ]; then
                  RESULT_LINE="• ID $CTID ($CTNAME): ⏭️ No APT found"
              elif [ "$LXC_UPD_RESULT" = "ERROR" ]; then
                  RESULT_LINE="• ID $CTID ($CTNAME): ❌ Error checking updates (Container offline or timed out)"
               elif [ ! -z "$LXC_UPD_RESULT_CLEAN" ] && [ "$LXC_UPD_RESULT_CLEAN" -gt 0 ] 2>/dev/null; then
                  RESULT_LINE="• ID $CTID ($CTNAME): ⚠️ *$LXC_UPD_RESULT_CLEAN* updates available"
              else
                  RESULT_LINE="• ID $CTID ($CTNAME): ✅ Up to date"
              fi

              # Save the formatted result line (plus disk usage) to a temporary file
              if [[ -n "$DISK_MSG" ]]; then
                  echo "$RESULT_LINE"$'\n'"$DISK_MSG" > "$TMP_DIR/$CTID"
              else
                  echo "$RESULT_LINE" > "$TMP_DIR/$CTID"
              fi
          ) &
          ((running_jobs++))

          # ⚡ Bolt: Bound concurrency using pure Bash counter to prevent subshell/process spawning overhead
          while (( running_jobs >= MAX_JOBS )); do
              wait -n || true
              ((running_jobs--))
          done
      done

      # Wait for all background checks to finish
      wait

      # Read the results in the original order
      for item in "${lxc_list[@]}"; do
          [[ -z "$item" ]] && continue
          CTID="${item%%:*}"
          if [ -f "$TMP_DIR/$CTID" ]; then
              # ⚡ Bolt: Use bash built-in redirection $(<...) instead of $(cat ...) to avoid spawning a subshell process per container
              REPORT+="$(<"$TMP_DIR/$CTID")"$'\n'
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
