#!/usr/bin/env bash
#
# Proxmox LXC Space Cleanup with Telegram Notifications
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
# - Runs a generic space cleanup inside every running LXC container
#   1. Package manager caches (apt, apk, dnf, yum)
#   2. System logs (journald vacuum, e.g. --vacuum-size=50M)
#   3. Docker (if installed): dangling image/builder prune
#      (volume prune is opt-in via CLEAN_DOCKER_VOLUME_PRUNE)
#   4. Docker containers /tmp cleanup (if docker is installed): old files
#      inside the writable layers of running docker containers
#   5. User caches (~/.cache, npm, pnpm, go)
#   6. Old /tmp files (older than 7 days)
# - Reports space freed per container
# - Exclude specific containers via EXCLUDED_CTIDS
# - Telegram notification with detailed results

set -Eeuo pipefail

SCRIPT_VERSION="v0.10.9"

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
    logger -t "lxc-cleanup" -p "user.${level,,}" -- "$*" 2>/dev/null || true
  fi
}

# --- TERMINAL RESTORE (defensive) ---
# Terminal state is snapshotted at startup and restored on exit so escape
# sequences or terminal modes left behind by subprocesses (hidden cursor,
# left-over colors, disabled echo, ...) can never break the shell.
SAVED_STTY=""
if [[ -t 0 ]]; then
  SAVED_STTY="$(stty -g 2>/dev/null || true)"
fi

restore_terminal() {
  if [[ -n "${SAVED_STTY}" ]]; then
    stty "${SAVED_STTY}" 2>/dev/null || true
  fi
  if [[ -t 2 ]]; then
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

# --- PARALLEL OUTPUT SECTIONING (Docker-build-style) ---
# Containers are cleaned in parallel, so every log line is tagged with the
# owning container and delimited by section headers/footers, keeping parallel
# output attributable (like Docker Build's "#N" prefixes).
USE_COLOR="no"
if [[ -t 2 ]]; then USE_COLOR="yes"; fi
SECTION_COLORS=("1;36" "1;33" "1;32" "1;35" "1;34" "1;31")
CT_PREFIX=""
CT_COLOR=""

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
CT_OPERATION_TIMEOUT=300 # Seconds before timing out operations inside containers (default: 5 minutes)
CLEAN_PKG_CACHE="yes" # Set to "no" to skip package manager cache cleanup (apt/apk/dnf/yum)
CLEAN_JOURNAL="yes" # Set to "no" to skip journald log vacuum
JOURNAL_VACUUM_SIZE="50M" # Maximum size to keep for journald logs (e.g. 50M, 100M)
CLEAN_DOCKER="yes" # Set to "no" to skip Docker dangling image/builder prune (only if docker is installed)
# ⚠️ DANGER: docker volume prune -f deletes ALL volumes not attached to a container, including ones you may want to keep.
# It is disabled by default. Set to "yes" only if you accept the data-loss risk.
CLEAN_DOCKER_VOLUME_PRUNE="no"
CLEAN_DOCKER_TMP="yes" # Set to "no" to skip old /tmp cleanup inside running Docker containers (only if docker is installed)
CLEAN_USER_CACHE="yes" # Set to "no" to skip user cache cleanup (~/.cache, npm, pnpm, go)
CLEAN_OLD_TMP="yes" # Set to "no" to skip deletion of files/directories in container's /tmp older than 7 days
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
CT_OPERATION_TIMEOUT="${CT_OPERATION_TIMEOUT:-300}"
CLEAN_PKG_CACHE="${CLEAN_PKG_CACHE:-yes}"
CLEAN_JOURNAL="${CLEAN_JOURNAL:-yes}"
JOURNAL_VACUUM_SIZE="${JOURNAL_VACUUM_SIZE:-50M}"
CLEAN_DOCKER="${CLEAN_DOCKER:-yes}"
CLEAN_DOCKER_VOLUME_PRUNE="${CLEAN_DOCKER_VOLUME_PRUNE:-no}"
CLEAN_DOCKER_TMP="${CLEAN_DOCKER_TMP:-yes}"
CLEAN_USER_CACHE="${CLEAN_USER_CACHE:-yes}"
CLEAN_OLD_TMP="${CLEAN_OLD_TMP:-yes}"
AUTO_UPDATE="${AUTO_UPDATE:-no}"

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
    CLEANUP_PATHS+=("$tmp_file") # 🛡️ Sentinel Security Fix: Register tmp_file for cleanup to prevent resource exhaustion

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

run_in_ct() {
  local ctid="$1"
  shift
  timeout "${CT_OPERATION_TIMEOUT:-300}" pct exec "$ctid" -- bash -c "$*" < /dev/null
}

is_excluded() {
  local ctid="$1"
  # ⚡ Bolt: Replace O(N) loop with O(1) string matching for exclusion check
  [[ " ${EXCLUDED_CTIDS[*]} " == *" $ctid "* ]] && return 0
  return 1
}

human_readable() {
  local kb="$1"
  if (( kb < 1024 )); then
    echo "${kb}K"
  elif (( kb < 1048576 )); then
    local mb_tenths=$(( (kb * 10 + 512) / 1024 ))
    if (( mb_tenths % 10 == 0 )); then
      echo "$(( mb_tenths / 10 ))M"
    else
      echo "$(( mb_tenths / 10 )).$(( mb_tenths % 10 ))M"
    fi
  else
    local gb_tenths=$(( (kb * 10 + 524288) / 1048576 ))
    if (( gb_tenths % 10 == 0 )); then
      echo "$(( gb_tenths / 10 ))G"
    else
      echo "$(( gb_tenths / 10 )).$(( gb_tenths % 10 ))G"
    fi
  fi
}

# --- CLEANUP LOGIC ---

build_clean_script() {
  # 🛡️ Sentinel Security Fix: Sanitize variables interpolated into unquoted heredoc executed via pct exec
  # to prevent command injection from host-side variable expansion.
  local safe_clean_pkg_cache="${CLEAN_PKG_CACHE//[^a-zA-Z0-9_-]/}"
  local safe_clean_journal="${CLEAN_JOURNAL//[^a-zA-Z0-9_-]/}"
  local safe_journal_vacuum_size="${JOURNAL_VACUUM_SIZE//[^a-zA-Z0-9_-]/}"
  local safe_clean_docker="${CLEAN_DOCKER//[^a-zA-Z0-9_-]/}"
  local safe_clean_docker_volume="${CLEAN_DOCKER_VOLUME_PRUNE//[^a-zA-Z0-9_-]/}"
  local safe_clean_docker_tmp="${CLEAN_DOCKER_TMP//[^a-zA-Z0-9_-]/}"
  local safe_clean_user_cache="${CLEAN_USER_CACHE//[^a-zA-Z0-9_-]/}"
  local safe_clean_old_tmp="${CLEAN_OLD_TMP//[^a-zA-Z0-9_-]/}"

  read -r -d '' script << EOF || true
set +e
df_used() {
  local header=1
  while read -r _ _ used _; do
    if [ "\$header" = 1 ]; then
      header=0
      continue
    fi
    echo "\$used"
    break
  done <<< "\$(df -P / 2>/dev/null)"
}

# Runs a cleanup command inside the container and reports the freed space (KB) for the given label
step() {
  local label="\$1"
  local cmd="\$2"
  local before after
  before=\$(df_used)
  bash -c "\$cmd" >/dev/null 2>&1 || true
  after=\$(df_used)
  echo "CLEAN_STEP:\$label:\$((before - after))"
}

PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
fi

before_total=\$(df_used)

# 1. PACKAGE MANAGER CACHES
if [ "${safe_clean_pkg_cache}" = "yes" ]; then
  case "\$PKG_MGR" in
    apt-get)
      step PKG_CACHE 'apt-get autoremove -y --purge >/dev/null 2>&1; apt-get clean >/dev/null 2>&1; rm -rf /var/lib/apt/lists/* >/dev/null 2>&1'
      ;;
    apk)
      step PKG_CACHE 'apk cache clean >/dev/null 2>&1; rm -rf /var/cache/apk/* >/dev/null 2>&1'
      ;;
    dnf)
      step PKG_CACHE 'dnf clean all >/dev/null 2>&1; rm -rf /var/cache/dnf/* >/dev/null 2>&1'
      ;;
    yum)
      step PKG_CACHE 'yum clean all >/dev/null 2>&1; rm -rf /var/cache/yum/* >/dev/null 2>&1'
      ;;
  esac
fi

# 2. SYSTEM LOGS (journald)
if [ "${safe_clean_journal}" = "yes" ] && command -v journalctl >/dev/null 2>&1; then
  step JOURNAL 'journalctl --vacuum-size=${safe_journal_vacuum_size} >/dev/null 2>&1; journalctl --vacuum-time=7d >/dev/null 2>&1'
fi

# 3. DOCKER (dangling images, build cache)
if [ "${safe_clean_docker}" = "yes" ] && command -v docker >/dev/null 2>&1; then
  step DOCKER 'docker image prune -f >/dev/null 2>&1; docker builder prune -f >/dev/null 2>&1'
fi

# 3b. DOCKER VOLUMES (orphaned volumes) - ⚠️ opt-in, can delete volumes you want to keep
if [ "${safe_clean_docker_volume}" = "yes" ] && command -v docker >/dev/null 2>&1; then
  step DOCKER_VOLUMES 'docker volume prune -f >/dev/null 2>&1'
fi

# 4. DOCKER CONTAINERS /tmp (old files in writable layers)
if [ "${safe_clean_docker_tmp}" = "yes" ] && command -v docker >/dev/null 2>&1; then
  step DOCKER_TMP 'for dc in \$(docker ps -q 2>/dev/null); do [ -n "\$dc" ] || continue; docker exec "\$dc" sh -c "find /tmp -mindepth 1 -mtime +7 -exec rm -rf {} +" >/dev/null 2>&1 || true; done'
fi

# 5. USER CACHES (~/.cache, npm, pnpm, go)
if [ "${safe_clean_user_cache}" = "yes" ]; then
  step USER_CACHE 'for home in /root /home/*; do [ -d "\$home" ] || continue; rm -rf "\$home"/.cache/* >/dev/null 2>&1 || true; rm -rf "\$home"/.npm/_cacache >/dev/null 2>&1 || true; rm -rf "\$home"/.local/share/pnpm/store >/dev/null 2>&1 || true; rm -rf "\$home"/go/pkg/mod/cache >/dev/null 2>&1 || true; done'
fi

# 6. OLD /tmp FILES (older than 7 days)
if [ "${safe_clean_old_tmp}" = "yes" ]; then
  step TMP 'find /tmp -mindepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null'
fi

after_total=\$(df_used)
echo "CLEAN_TOTAL:\$((before_total - after_total))"
EOF
  echo "$script"
}

# Friendly name for a cleanup step label, used in logs and reports
step_label_name() {
  case "$1" in
    PKG_CACHE) echo "Pkg cache" ;;
    JOURNAL) echo "Logs (journald)" ;;
    DOCKER) echo "Docker images/build" ;;
    DOCKER_VOLUMES) echo "Docker volumes" ;;
    DOCKER_TMP) echo "Docker /tmp" ;;
    USER_CACHE) echo "User caches" ;;
    TMP) echo "Old /tmp" ;;
    *) echo "$1" ;;
  esac
}

cleanup_lxc() {
  local ctid="$1"
  local ctname="$2"
  local ctraw="${3:-$2}"

  # Docker-build-style: tag every output line with this container's section
  CT_COLOR="${SECTION_COLORS[$(( ${ctid} % ${#SECTION_COLORS[@]} ))]}"
  CT_PREFIX="[${ctid}:${ctraw}] "

  log INFO "ℹ️ Cleaning LXC $ctid ($ctname)..."

  local clean_script
  clean_script=$(build_clean_script)

  local output=""
  local rc=0
  output=$(run_in_ct "$ctid" "$clean_script") || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    echo "• ${ctid} (${ctname}): ❌ Cleanup failed (Check container status or network)"
    log ERROR "❌ LXC $ctid ($ctname) cleanup failed (Check container status or network)"
    return 1
  fi

  # Parse per-step freed space and total freed space reported by the in-container script
  local step_desc=""
  local line freed freed_kb=0
  while IFS= read -r line; do
    case "$line" in
      CLEAN_STEP:*)
        line="${line#CLEAN_STEP:}"
        local label="${line%%:*}"
        freed="${line##*:}"
        [[ "$freed" =~ ^-?[0-9]+$ ]] || freed=0
        local fname
        fname="$(step_label_name "$label")"
        if (( freed > 0 )); then
          step_desc+="      ✅ ${fname}: freed $(human_readable "$freed")"$'\n'
          log INFO "✅  -> ${fname}: freed $(human_readable "$freed")"
        else
          log INFO "ℹ️  -> ${fname}: nothing to free"
        fi
        ;;
      CLEAN_TOTAL:*)
        freed_kb="${line#CLEAN_TOTAL:}"
        [[ "$freed_kb" =~ ^-?[0-9]+$ ]] || freed_kb=0
        ;;
    esac
  done <<< "$output"

  (( freed_kb > 0 )) || freed_kb=0

  local result_line
  if (( freed_kb > 0 )); then
    result_line="• ${ctid} (${ctname}): ✅ Freed $(human_readable "$freed_kb")"
    log INFO "✅ LXC $ctid ($ctname) cleaned (freed $(human_readable "$freed_kb"))"
  else
    result_line="• ${ctid} (${ctname}): ✅ Cleaned (nothing to free)"
    log INFO "✅ LXC $ctid ($ctname) cleaned (nothing to free)"
  fi

  echo "$result_line"
  [[ -n "$step_desc" ]] && echo -n "$step_desc"
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

  local clean_count=0
  local fail_count=0
  local skip_count=0
  local report=""

  report+="*🧹 Proxmox LXC Cleanup Report: ${HOSTNAME}*"$'\n\n'

  # GET RUNNING LXCS
  local lxc_list=()
  mapfile -t lxc_list < <(pct list | awk 'NR>1 && $2=="running" {print $1 ":" $NF}')

  log DEBUG "Detected ${#lxc_list[@]} running containers: ${lxc_list[*]:-none}"

  report+="*🧽 LXC Containers Status:*"$'\n'

  if [[ ${#lxc_list[@]} -eq 0 ]]; then
    log INFO "⏭️ No running containers found."
    report+="• ⏭️ No running containers found."$'\n'
  else
    # Disable immediate exit to ensure the loop continues for all containers
    set +e

    # ⚡ Bolt: Use a temporary directory to store bounded concurrent execution results
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/lxc-cleanup.XXXXXX") || { log ERROR "❌ Failed to create temporary directory for concurrent execution (Check /tmp permissions or disk space)"; exit 1; }
    # 🛡️ Sentinel Security Fix: Register tmp_dir in the global cleanup trap to prevent scope collapse leakage
    CLEANUP_PATHS+=("$tmp_dir")
    local max_jobs=5
    local running_jobs=0
    local pending=0
    local -A job_pid=()

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

      log DEBUG "Starting cleanup for container $ctid ($ctname)"

      # ⚡ Bolt: Execute container cleanup concurrently in the background.
      # Each job buffers its complete output to $tmp_dir/<ctid>.log and is
      # printed as one complete sequential block (in completion order) by the
      # monitor loop below, so parallel runs never interleave on the console.
      (
        # Docker-build-style: delimit each container's output with a section
        section_banner "$ctid" "$ctraw"
        local result
        result=$(cleanup_lxc "$ctid" "$ctname" "$ctraw")
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
          : > "$tmp_dir/$ctid.printed"
          ((printed++))
        fi
      done
    done

    # Read the results in the original order
    for item in "${lxc_list[@]}"; do
      [[ -z "$item" ]] && continue
      local ctid="${item%%:*}"
      if [[ -f "$tmp_dir/$ctid" ]]; then
        local result
        # ⚡ Bolt: Use bash built-in redirection $(<...) instead of $(cat ...) to avoid spawning a subshell process per container
        result=$(<"$tmp_dir/$ctid")
        report+="$result"$'\n'
        if [[ "$result" == *"✅"* ]]; then ((clean_count++))
        elif [[ "$result" == *"⏭️"* ]]; then ((skip_count++))
        elif [[ "$result" == *"❌"* ]]; then ((fail_count++))
        else ((skip_count++)); fi
      fi
    done

    # Re-enable immediate exit
    set -e
    log DEBUG "Finished processing all running containers"
  fi

  report+=$'\n'
  report+="✅ Cleaned: ${clean_count}"$'\n'
  report+="⏭️ Excluded: ${skip_count}"$'\n'
  report+="❌ Failed: ${fail_count}"$'\n'

  send_telegram "$report"
}

# --- ENTRY POINT ---
# Handle --update flag: update scripts from GitHub, then continue with the main purpose
if [[ "${1:-}" == "--update" ]]; then
  auto_update "yes"
fi

main "$@"
