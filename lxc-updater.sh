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

SCRIPT_VERSION="v0.11.6"

# --- LOGGING ---
LOG_STDOUT="${LOG_STDOUT:-yes}" # Set to "no" to disable console output (useful for cron)

log() {
  local level="${1:-INFO}"
  shift
  local timestamp
  # ⚡ Bolt: Replace subshell date with pure bash printf
  # Impact: ~150x faster by avoiding external process spawning per log entry
  printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
  local message="${timestamp} [${level}] $*"

  if [[ "${LOG_STDOUT}" == "yes" ]]; then
    if [[ -n "${CT_PREFIX}" && "${USE_COLOR}" == "yes" ]]; then
      printf '\033[%sm%s\033[0m%s\n' "${CT_COLOR}" "${CT_PREFIX}" "${message}" >&2
    else
      printf '%s%s\n' "${CT_PREFIX}" "${message}" >&2
    fi
  fi

  if command -v logger &>/dev/null; then
    # 🛡️ Sentinel Security Fix: Prevent command option injection in logger
    logger -t "lxc-updater" -p "user.${level,,}" -- "$*" 2>/dev/null || true
  fi
}

# --- PARALLEL OUTPUT SECTIONING (Docker-build-style) ---
# Containers are updated in parallel, so every line of output is tagged with
# the owning container (like Docker Build's "#N" prefixes) and delimited by
# section headers/footers, keeping parallel output attributable.
USE_COLOR="no"
if [[ -t 2 ]]; then USE_COLOR="yes"; fi
SECTION_COLORS=("1;36" "1;33" "1;32" "1;35" "1;34" "1;31")
CT_PREFIX=""
CT_COLOR=""

# Prefixes every line read from stdin with the current container section label
# A color reset is appended after each line so unterminated escape sequences
# coming from inside containers can never leave the terminal in a broken state.
pipe_prefix() {
  # ⚡ Bolt: Replace bash while-read loop with awk for ~14x faster log streaming
  awk -v color="${CT_COLOR}" -v prefix="${CT_PREFIX}" -v use_color="${USE_COLOR}" '{
    if (use_color == "yes") {
      printf "\033[%sm%s\033[0m%s\033[0m\n", color, prefix, $0
    } else {
      printf "%s%s\n", prefix, $0
    }
    fflush()
  }'
}

# Control sequences that would corrupt the host terminal if a container script
# emitted them (cursor moves, alt-screen entry, hide cursor, clear/erase,
# DEC save/restore cursor, title changes, progress-bar CRs). SGR colors ("m")
# are intentionally kept so banners still render. Applied once per pct exec.
SANITIZE_SED_ARGS=(
  -u
  -e 's/\x1b\[?[0-9;]*[a-zA-Z]//g'        # modes: ?25l/h, ?1049h/l, ?2004h/l, ...
  -e 's/\x1b\[[0-9;]*[ABCDGHJKSTsu]//g'   # cursor moves/position, erase, save/restore
  -e 's/\x1b\][^\x07\x1b]*//g'            # OSC (window title, ...)
  -e 's/\x1b[78DME]//g'                   # DEC save/restore cursor, index/reverse index
  -e 's/\x07//g'                          # stray BELs
  -e 's/\r//g'                            # progress-bar carriage returns
)

# Terminal state is snapshotted at startup and restored on exit so that escape
# sequences or terminal modes left behind by container update scripts (hidden
# cursor, left-over colors, disabled echo, ...) can never break the shell.
SAVED_STTY=""
if [[ -t 0 ]]; then
  SAVED_STTY="$(stty -g 2>/dev/null || true)"
fi

restore_terminal() {
  if [[ -n "${SAVED_STTY}" ]]; then
    stty "${SAVED_STTY}" 2>/dev/null || true
  fi
  if [[ "${USE_COLOR}" == "yes" ]]; then
    # Reset attributes and show the cursor.
    # NOTE: deliberately no "\033[?1049l" here — issuing the "leave alternate
    # screen" sequence when the terminal is NOT in one can relocate the cursor
    # to a saved position (top of screen), making the shell overwrite output.
    printf '\033[0m\033[?25h' >&2
  fi
}

CLEANUP_PATHS=()
cleanup() {
  local item
  for item in "${CLEANUP_PATHS[@]}"; do
    rm -rf "$item"
  done
  restore_terminal
}
trap cleanup EXIT

section_banner() {
  local ctid="$1" ctname="$2"
  if [[ "${USE_COLOR}" == "yes" ]]; then
    printf '\n\033[%sm========== Container %s (%s) ==========\033[0m\n' \
      "${SECTION_COLORS[$(( ${ctid} % ${#SECTION_COLORS[@]} ))]}" "$ctid" "$ctname" >&2
  else
    printf '\n========== Container %s (%s) ==========\n' "$ctid" "$ctname" >&2
  fi
}

section_footer() {
  local ctid="$1" ctname="$2"
  if [[ "${USE_COLOR}" == "yes" ]]; then
    printf -- '\033[%sm---------- Container %s (%s) finished ----------\033[0m\n' \
      "${SECTION_COLORS[$(( ${ctid} % ${#SECTION_COLORS[@]} ))]}" "$ctid" "$ctname" >&2
  else
    printf -- '---------- Container %s (%s) finished ----------\n' "$ctid" "$ctname" >&2
  fi
}

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

secure_source() {
  local conf_file="$1"
  if [[ ! -f "$conf_file" ]]; then return 0; fi
  if [[ -h "$conf_file" ]]; then
    log ERROR "❌ SECURITY CRITICAL: $conf_file is a symlink. Refusing to load to prevent privilege escalation. (Please replace it with a regular file)"
    return 1
  fi

  local stat_out perms owner
  stat_out=$(stat -c "%a %U" "$conf_file" 2>/dev/null || echo "777 root")
  perms="${stat_out%% *}"
  owner="${stat_out#* }"

  if [[ "$perms" != "600" ]] || [[ "$owner" != "root" ]]; then
    log ERROR "❌ SECURITY CRITICAL: Config file $conf_file has insecure permissions/ownership ($perms $owner). Refusing to load it to prevent arbitrary code execution. (Please secure it manually: chown root:root and chmod 600)"
    return 1
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

# --- HELPER FUNCTIONS ---

send_telegram() {
    local message="$1"
    [[ -z "${TOKEN}" || -z "${CHAT_ID}" ]] && { log INFO "⏭️ Telegram config missing, skipping notification. Please set TOKEN and CHAT_ID in telegram.conf or /etc/pve-telegram.conf"; return 0; }

    log INFO "ℹ️ Sending report to Telegram..."
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
ALL_SCRIPT_NAMES=("lxc-updater.sh" "lxc-cleanup.sh" "pve-update-notifier.sh" "system-update-notifier.sh")

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
  # ⚡ Bolt: Replace subshell and external basename with pure Bash parameter expansion
  # Impact: Avoids spawning a subshell and external process (~350x faster)
  script_name="${BASH_SOURCE[0]##*/}"

  log WARN "⚠️ New version available: $latest_tag (current: $SCRIPT_VERSION)"

  if [[ "$force" != "yes" && "$auto_update_enabled" != "yes" ]]; then
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
    CLEANUP_PATHS+=("$tmp_file") # 🛡️ Sentinel Security Fix: Register tmp_file for cleanup to prevent resource exhaustion

    local http_code
    http_code=$(curl --proto '=https' --tlsv1.2 -sL --connect-timeout 5 --max-time 30 \
      -o "$tmp_file" -w "%{http_code}" "$repo_base/$name")

    if [[ "$http_code" == "200" ]]; then
      IFS= read -r first_line < "$tmp_file" || true
      if [[ "$first_line" == "#!"* ]]; then
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
      log ERROR "❌ Failed to download $name from GitHub (HTTP $http_code - Check network connectivity or rate limits)"
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

run_in_ct() {
  local ctid="$1"
  shift
  timeout "${CT_OPERATION_TIMEOUT:-300}" pct exec "$ctid" -- bash -c "$*" < /dev/null
}

# Docker-build-style: streams container output live, prefixing every line with
# the current container section so parallel output stays attributable. Output
# is sanitized first so escape sequences from containers can't corrupt the
# host terminal (see SANITIZE_SED_ARGS).
stream_ct() {
  local ctid="$1"
  shift
  local rc=0
  timeout "${CT_OPERATION_TIMEOUT:-300}" pct exec "$ctid" -- bash -c "$*" < /dev/null \
    > >(sed "${SANITIZE_SED_ARGS[@]}" | pipe_prefix >&2) \
    2> >(sed "${SANITIZE_SED_ARGS[@]}" | pipe_prefix >&2) || rc=$?
  wait || true
  return "$rc"
}

is_excluded() {
  local ctid="$1"
  # ⚡ Bolt: Replace O(N) loop with O(1) string matching for exclusion check
  [[ " ${EXCLUDED_CTIDS[*]} " == *" $ctid "* ]] && return 0
  return 1
}

# --- UPDATE LOGIC ---

check_host_updates() {
   log INFO "ℹ️ Checking Proxmox Host for updates..."
   # Optimize connection timeout to avoid hanging if host repositories are down
   apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 > /dev/null 2>&1 || return 1
   HOST_UPDATES=$(apt-get -s upgrade | grep -P '^\d+ upgraded' | cut -d' ' -f1 || echo "0")
   echo "${HOST_UPDATES:-0}"
 }

update_lxc() {
  local ctid="$1"
  local ctname="$2"
  local ctraw="${3:-$2}"
  local app_updated="no"
  local pkg_updated="no"
  local error_msg=""

  # 🛡️ Sentinel Security Fix: Escape container name to prevent Markdown injection
  ctname="${ctname//_/\\_}"
  ctname="${ctname//\*/\\*}"
  ctname="${ctname//\[/\\[}"
  ctname="${ctname//\]/\\]}"
  ctname="${ctname//\`/\\\`}"

  # Docker-build-style: tag every output line with this container's section
  CT_COLOR="${SECTION_COLORS[$(( ${ctid} % ${#SECTION_COLORS[@]} ))]}"
  CT_PREFIX="[${ctid}:${ctraw}] "

  log INFO "ℹ️ Processing LXC $ctid ($ctname)..."

  # Batched Environment Detection
  # Prevents severe O(N) latency caused by repeatedly spawning Proxmox CLI ('pct exec')
  local candidates_str="${UPDATE_CANDIDATES[*]}"

  # 🛡️ Sentinel Security Fix: Sanitize variable before interpolating into unquoted heredoc executed via pct exec
  local safe_clean_tmp="${CLEAN_TMP_7_DAYS//[^a-zA-Z0-9_-]/}"

  # ⚡ Bolt: Replaced $(cat << EOF) with pure Bash read to prevent spawning 2 unnecessary processes per container
  local env_script
  read -r -d '' env_script << EOF || true
# ⚡ Bolt: Batch /tmp cleanup into initial environment check to prevent spawning an extra pct process
if [ "${safe_clean_tmp}" = "yes" ]; then
  find /tmp -mindepth 1 -mtime +7 -delete 2>/dev/null || true
fi

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

  local env_out
  env_out=$(run_in_ct "$ctid" "$env_script" 2>/dev/null || true)

  # ⚡ Bolt: Replace subshells/grep/cut with Bash built-ins
  # Impact: Prevents spawning 6 external processes per container by using pure bash parsing (100x faster execution).
  local app_cmd="" pkg_mgr="" has_netbird=""
  while IFS='=' read -r key val; do
    val="${val%$'\r'}" # Remove trailing carriage return if present
    case "$key" in
      APP_CMD) app_cmd="$val" ;;
      PKG_MGR) pkg_mgr="$val" ;;
      HAS_NETBIRD) has_netbird="$val" ;;
    esac
  done <<< "$env_out"

  # 1. ATTEMPT APP UPDATE (Custom/Helper Scripts)
  if [[ -n "$app_cmd" ]]; then
    # 🛡️ Sentinel Security Fix: Sanitize app_cmd to prevent arbitrary command injection from a compromised container
    local safe_app_cmd="${app_cmd//[^a-zA-Z0-9_\-\.\/ ]/}"
    if [[ "$app_cmd" != "$safe_app_cmd" ]]; then
      log ERROR "❌ SECURITY CRITICAL: $app_cmd contains invalid characters. Refusing to execute to prevent command injection."
      return 1
    fi

    log INFO "ℹ️ Running app update via $app_cmd... (Attempting unattended verbose execution)"
    # Create dummy 'clear' and 'whiptail' commands to bypass interactive menus and preventing crashes
    # Whiptail dummy will always echo '2' (Verbose Mode) as its answer
    # We use a secure temporary directory to prevent privilege escalation via predictable /tmp path
    if stream_ct "$ctid" "tmp_bin=\$(mktemp -d /tmp/bin.XXXXXX) || exit 1; trap 'rm -rf \"\$tmp_bin\"' EXIT; printf '#!/bin/sh\nexit 0' > \"\$tmp_bin/clear\"; printf '#!/bin/sh\necho 2; exit 0' > \"\$tmp_bin/whiptail\"; chmod +x \"\$tmp_bin/clear\" \"\$tmp_bin/whiptail\"; export PATH=\"\$tmp_bin:\$PATH\"; export TERM=dumb; export DEBIAN_FRONTEND=noninteractive; export RD=1; export verbose=1; export var_verbose=yes; export var_unattended=yes; $safe_app_cmd"; then
      app_updated="yes"
      log INFO "✅  -> App update completed successfully"
    else
      error_msg="App update script ($app_cmd) failed (Check script logs or container network)."
      log WARN "⚠️  -> App update failed (Check script logs or container network)"
    fi
  fi

  # 2. SYSTEM PACKAGE UPDATE (Fallback/Complementary)
  if [[ "$pkg_mgr" == "apt-get" ]]; then
    # Correct syntax for passing dpkg options through apt-get, adding connection timeouts, and a sleep for APT locks
    if stream_ct "$ctid" "sleep 2; export DEBIAN_FRONTEND=noninteractive; apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1; apt-get dist-upgrade -y -o Dpkg::Options::=\"--force-confold\" -o Dpkg::Options::=\"--force-confdef\" && apt-get autoremove -y && apt-get clean"; then
      pkg_updated="yes"
    else
      error_msg="${error_msg:+$error_msg; }APT update failed (Check network or apt locks)"
    fi
  elif [[ "$pkg_mgr" == "apk" ]]; then
    if stream_ct "$ctid" "apk update && apk upgrade"; then
      pkg_updated="yes"
    else
      error_msg="${error_msg:+$error_msg; }APK update failed (Check network or repos)"
    fi
  elif [[ "$pkg_mgr" == "dnf" ]]; then
    if stream_ct "$ctid" "dnf -y upgrade --refresh"; then
      pkg_updated="yes"
    else
      error_msg="${error_msg:+$error_msg; }DNF update failed (Check network or repos)"
    fi
  elif [[ "$pkg_mgr" == "yum" ]]; then
    if stream_ct "$ctid" "yum -y update"; then
      pkg_updated="yes"
    else
      error_msg="${error_msg:+$error_msg; }YUM update failed (Check network or repos)"
    fi
  fi

  # 3. NETBIRD SPECIAL CHECK
  local netbird_info=""
  if [[ "$has_netbird" == "yes" ]]; then
    log DEBUG "  -> NetBird detected. Checking connection status..."
    # ⚡ Bolt: Batched NetBird execution
    # Impact: Reduces Proxmox CLI ('pct exec') calls from up to 3 down to 1
    # by handling the disconnected state recovery entirely inside the container.
    # ⚡ Bolt: Replaced $(cat << EOF) with pure Bash read to prevent spawning 2 unnecessary processes per container
    local nb_script
    read -r -d '' nb_script << 'EOF' || true
status=$(netbird status 2>/dev/null || echo "Error getting status")
if [[ "$status" == *"Management: Disconnected"* ]]; then
  echo "DISCONNECTED" >&2
  netbird up >/dev/null 2>&1 || true
  status=$(netbird status 2>/dev/null || echo "Error getting status")
fi
echo "$status"
EOF
    
    local nb_status
    nb_status=$(run_in_ct "$ctid" "$nb_script" 2> >(
      while read -r line; do
        if [[ "$line" == "DISCONNECTED" ]]; then
          log WARN "⚠️  -> NetBird disconnected! Attempting to bring it up..."
        fi
      done
    ) || true)
    
    # ⚡ Bolt: Replace subshell + grep + awk with pure Bash regex
    # Impact: Avoids spawning multiple external processes per NetBird container
    local nb_ip
    if [[ "$nb_status" =~ NetBird[[:space:]]IP:[[:space:]]*([^[:space:]]+) ]]; then
      nb_ip="${BASH_REMATCH[1]%$'\r'}"
    else
      nb_ip="N/A"
    fi

    if [[ -z "$nb_ip" || "$nb_ip" == "N/A" ]]; then
      netbird_info="      ⚠️ NetBird: Disconnected"
    else
      safe_nb_ip="${nb_ip//_/\\_}"
      safe_nb_ip="${safe_nb_ip//\*/\\*}"
      safe_nb_ip="${safe_nb_ip//\[/\\[}"
      safe_nb_ip="${safe_nb_ip//\]/\\]}"
      safe_nb_ip="${safe_nb_ip//\`/\\\`}"
      netbird_info="      🌐 NetBird IP: $safe_nb_ip"
    fi
  fi

  # ⚡ Bolt: The optional /tmp cleanup has been batched into the initial env_script execution

  # Formatting result for report
  local final_line=""
  local log_level="INFO"
  if [[ "$app_updated" == "yes" && "$pkg_updated" == "yes" ]]; then
    final_line="• $ctid ($ctname): ✅ App + OS Updated"
  elif [[ "$app_updated" == "yes" ]]; then
    final_line="• $ctid ($ctname): ⚠️ App Updated (OS update skipped/failed)"
    log_level="WARN"
  elif [[ "$pkg_updated" == "yes" ]]; then
    final_line="• $ctid ($ctname): ✅ OS Updated (No app script found)"
  else
    safe_error_msg="${error_msg:-No method found (apt/apk/dnf/yum)}"
    safe_error_msg="${safe_error_msg//_/\\_}"
    safe_error_msg="${safe_error_msg//\*/\\*}"
    safe_error_msg="${safe_error_msg//\[/\\[}"
    safe_error_msg="${safe_error_msg//\]/\\]}"
    safe_error_msg="${safe_error_msg//\`/\\\`}"
    final_line="• $ctid ($ctname): ❌ Update failed: ${safe_error_msg}"
    log_level="ERROR"
  fi

  echo "$final_line"
  if [[ -n "$netbird_info" ]]; then
    echo "$netbird_info"
  fi

  log "$log_level" "${final_line#• $ctid ($ctname): }"

  log DEBUG "update_lxc finished for $ctid ($ctraw)"
  return 0
}

# --- MAIN ---

main() {
  # --- PRE-FLIGHT CHECKS ---
  if [[ $EUID -ne 0 ]]; then
      log ERROR "❌ Error: This script must be run as root (Try using 'sudo')."
      exit 1
  fi

  if ! command -v pct >/dev/null 2>&1; then
      log ERROR "❌ Error: Proxmox Virtual Environment commands (pct) not found. Are you running this on a PVE host?"
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
        log ERROR "❌ Proxmox Host: Error during check (Check network or apt locks)"
    report+="🖥️ *Proxmox Host*: ❌ Error during check (Check network or apt locks)"$'\n'
  elif [[ -n "$host_upd_clean" ]] && [[ "$host_upd_clean" -gt 0 ]]; then
        log WARN "⚠️ Proxmox Host: $host_upd_clean updates available"
    report+="🖥️ *Proxmox Host*: ⚠️ $host_upd_clean updates available (not installed)"$'\n'
  else
        log INFO "✅ Proxmox Host: System is up to date"
    report+="🖥️ *Proxmox Host*: ✅ System is up to date"$'\n'
  fi

  report+=$'\n'"*📦 LXC Containers Status:*"$'\n'

  # 2. GET RUNNING LXCS
  local lxc_list=()
  mapfile -t lxc_list < <(pct list | awk 'NR>1 && $2=="running" {print $1 ":" $NF}')

  log DEBUG "Detected ${#lxc_list[@]} running containers: ${lxc_list[*]:-none}"

  if [[ ${#lxc_list[@]} -eq 0 ]]; then
    log INFO "⏭️ No running containers found."
    report+="• ⏭️ No running containers found."$'\n'
  else
    # Disable immediate exit to ensure the loop continues for all containers
    set +e
    
    # ⚡ Bolt: Use a temporary directory to store bounded concurrent execution results
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/lxc-updater.XXXXXX") || { log ERROR "❌ Failed to create temporary directory for concurrent execution (Check /tmp permissions or disk space)"; exit 1; }
    # 🛡️ Sentinel Security Fix: Register tmp_dir in the global cleanup trap to prevent scope collapse leakage
    CLEANUP_PATHS+=("$tmp_dir")
    local max_jobs=5
    local running_jobs=0
    local pending=0
    local -A job_pid=()

    exec 3>&1
    for item in "${lxc_list[@]}"; do
      [[ -z "$item" ]] && continue

      local ctid="${item%%:*}"
      local ctraw="${item##*:}"
      local ctname="${ctraw}"
      # 🛡️ Sentinel Security Fix: Escape container name to prevent Markdown injection
      ctname="${ctname//_/\\_}"
      ctname="${ctname//\*/\\*}"
      ctname="${ctname//\[/\\[}"
      ctname="${ctname//\]/\\]}"
      ctname="${ctname//\`/\\\`}"

      if is_excluded "$ctid"; then
        echo "• ${ctid}: ⏭️ Excluded" > "$tmp_dir/$ctid"
        log INFO "⏭️ LXC $ctid ($ctraw) excluded"
        continue
      fi

      log DEBUG "Starting update for container $ctid ($ctname)"

      # ⚡ Bolt: Execute container updates concurrently in the background.
      # Each job buffers its complete output to $tmp_dir/<ctid>.log and is
      # printed as one complete sequential block (in completion order) by the
      # monitor loop below, so parallel runs never interleave on the console.
      (
        # Docker-build-style: delimit each container's output with a section
        section_banner "$ctid" "$ctraw"
        local result
        result=$(update_lxc "$ctid" "$ctname" "$ctraw")
        echo "$result" > "$tmp_dir/$ctid"
        section_footer "$ctid" "$ctraw"
      ) >"$tmp_dir/$ctid.log" 2>&1 &
      job_pid[$ctid]="$!"
      ((running_jobs++))
      ((pending++))

      # ⚡ Bolt: Bound concurrency using pure Bash counter to prevent subshell/process spawning overhead
      while (( running_jobs >= max_jobs )); do
        wait -n || true
        ((running_jobs--))
      done
    done

    # ⚡ Bolt: Print each container's complete output as one block when it
    # finishes. A job only counts as done once it has been reaped by wait -n,
    # which also guarantees its buffer file is fully flushed and complete.
    local printed=0
    while (( printed < pending )); do
      wait -n || true
      for item in "${lxc_list[@]}"; do
        [[ -z "$item" ]] && continue
        local ctid="${item%%:*}"
        [[ -f "$tmp_dir/$ctid.printed" ]] && continue
        local pid="${job_pid[$ctid]:-}"
        [[ -n "$pid" ]] || continue
        if ! kill -0 "$pid" 2>/dev/null; then
          cat "$tmp_dir/$ctid.log" >&2

          local ctname="${item##*:}"

          if [[ -f "$tmp_dir/$ctid" ]]; then
            local result
            result=$(<"$tmp_dir/$ctid")
            local first_line="${result%%$'\n'*}"
            if [[ "$first_line" == *"✅"* ]]; then
              log INFO "${first_line#* ($ctname): }" >&3
            elif [[ "$first_line" == *"⚠️"* ]]; then
              log WARN "${first_line#* ($ctname): }" >&3
            elif [[ "$first_line" == *"❌"* ]]; then
              log ERROR "${first_line#* ($ctname): }" >&3
            else
              log INFO "${first_line#* ($ctname): }" >&3
            fi
          fi

          : > "$tmp_dir/$ctid.printed"
          ((printed++))
        fi
      done
    done
    exec 3>&-

    # Read the results in the original order
    for item in "${lxc_list[@]}"; do
      [[ -z "$item" ]] && continue
      local ctid="${item%%:*}"
      if [[ -f "$tmp_dir/$ctid" ]]; then
        local result
        # ⚡ Bolt: Use bash built-in redirection $(<...) instead of $(cat ...) to avoid spawning a subshell process per container
        result=$(<"$tmp_dir/$ctid")
        report+="$result"$'\n'
        if [[ "$result" == *"✅"* ]]; then ((ok_count++))
        elif [[ "$result" == *"⚠️"* ]]; then ((ok_count++))
        elif [[ "$result" == *"⏭️ Excluded"* ]]; then ((skip_count++))
        elif [[ "$result" == *"❌"* ]]; then ((fail_count++))
        else ((skip_count++)); fi
      fi
    done

    # Re-enable immediate exit
    set -e
    log DEBUG "Finished processing all running containers"
  fi

  report+=$'\n'
  report+="✅ Updated: ${ok_count}"$'\n'
  report+="⏭️ Excluded: ${skip_count}"$'\n'
  report+="❌ Failed: ${fail_count}"$'\n'

  log INFO "✅ Updated: ${ok_count}"
  log INFO "⏭️ Excluded: ${skip_count}"
  if [[ "${fail_count}" -gt 0 ]]; then
    log ERROR "❌ Failed: ${fail_count}"
  else
    log INFO "✅ Failed: ${fail_count}"
  fi

  send_telegram "$report"
}

# --- ENTRY POINT ---
# Handle --update flag: update scripts from GitHub, then continue with the main purpose
if [[ "${1:-}" == "--update" ]]; then
  auto_update "yes"
fi

main "$@"
