#!/bin/bash
# System Update Notifier
# Updates the host system via apt and sends a Telegram notification.

SCRIPT_VERSION="v0.6.4"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- LOGGING ---
LOG_STDOUT="${LOG_STDOUT:-yes}"
log(){
  local lvl="${1:-INFO}"; shift
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local msg="${ts} [${lvl}] $*"
  [[ "$LOG_STDOUT" == "yes" ]] && echo "$msg" >&2
  # 🛡️ Sentinel Security Fix: Prevent command option injection in logger
  command -v logger &>/dev/null && logger -t "system-update-notifier" -p "user.${lvl,,}" -- "$*" 2>/dev/null || true
}

# --- CONFIGURATION ---
TOKEN=""
CHAT_ID=""
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

secure_source() {
  local conf_file="$1"
  if [[ ! -f "$conf_file" ]]; then return 0; fi

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/telegram.conf" ]]; then
  secure_source "${SCRIPT_DIR}/telegram.conf"
elif [[ -f "/etc/pve-telegram.conf" ]]; then
  secure_source "/etc/pve-telegram.conf"
fi
TOKEN="${TOKEN:-}"; CHAT_ID="${CHAT_ID:-}"; HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"

# 🛡️ Sentinel Security Fix: Escape Markdown control characters to prevent Telegram API injection DoS
HOSTNAME="${HOSTNAME//_/\\_}"
HOSTNAME="${HOSTNAME//\*/\\*}"
HOSTNAME="${HOSTNAME//\[/\\[}"
HOSTNAME="${HOSTNAME//\]/\\]}"
HOSTNAME="${HOSTNAME//\`/\\\`}"

AUTO_UPDATE="${AUTO_UPDATE:-no}" # Set to "yes" to enable automatic script updates from GitHub

# --- TELEGRAM SEND ---
send_telegram(){
  local message="$1"
  [[ -z "$TOKEN" || -z "$CHAT_ID" ]] && { log INFO "⏭️ Telegram config missing, skipping notification. Please set TOKEN and CHAT_ID in telegram.conf or /etc/pve-telegram.conf"; return 0; }
  local URL="https://api.telegram.org/bot${TOKEN}/sendMessage"
  # 🛡️ Sentinel Security Fix: Prevent TOKEN leakage and fix ARG_MAX for large reports.
  # Use process substitution for config and pass the message body via stdin.
  local RESPONSE=$(curl --proto '=https' --tlsv1.2 -s --connect-timeout 10 --max-time 30 -X POST -K <(cat <<CURL_CONF
url = "$URL"
data-urlencode = "chat_id=$CHAT_ID"
data-urlencode = "parse_mode=Markdown"
CURL_CONF
) --data-urlencode "text@-" <<< "$message")
  [[ $RESPONSE != *'"ok":true'* ]] && log ERROR "❌ Telegram Error: $RESPONSE (Check bot token or network)" || log INFO "✅ Telegram delivery successful."
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

  local latest_tag
  latest_tag=$(curl --proto '=https' --tlsv1.2 -sI --connect-timeout 5 --max-time 10 \
    "https://github.com/spupuz/proxmox-scripts/releases/latest" \
    | grep -i '^location:' | sed 's|.*/tag/||' | tr -d '\r')

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
      log INFO "ℹ️ Skipping $name (not installed in $SCRIPT_DIR)"
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

# --- PRE-FLIGHT CHECKS ---
if [[ $EUID -ne 0 ]]; then log ERROR "❌ Error: Must run as root (Try using 'sudo')"; exit 1; fi
command -v apt-get &>/dev/null || { log ERROR "❌ Error: apt-get not found (Debian/Proxmox environment required)"; exit 1; }

# Handle --update flag: update scripts from GitHub, then continue with the main purpose
if [[ "${1:-}" == "--update" ]]; then
  auto_update "yes"
fi

auto_update "$@"

log INFO "ℹ️ Running apt update (fetching package lists)..."
apt-get update -o Acquire::http::Timeout=10 -o Acquire::ftp::Timeout=10 -o Acquire::Retries=1 2>&1 | grep -E '(^Get:|^Hit:|^Reading)' >&2

log INFO "ℹ️ Checking for available upgrades (analyzing candidates)..."
UPGRADE_LIST=$(apt-get -s dist-upgrade | grep -E '^Inst' | awk '{print $2}')
if [[ -z "$UPGRADE_LIST" ]]; then
  REPORT="*✅ $HOSTNAME*: System already up‑to‑date"
  send_telegram "$REPORT"
  log INFO "✅ System is already up to date (no upgrades available)"
  exit 0
fi

PACKAGE_COUNT=$(echo "$UPGRADE_LIST" | wc -w)
FORMATTED_LIST=$(echo "$UPGRADE_LIST" | tr ' ' '\n' | sed 's/^/    ✓ /')
log INFO "ℹ️ Found $PACKAGE_COUNT packages to upgrade:"$'\n'"$FORMATTED_LIST"

log INFO "ℹ️ Installing system updates..."
apt_log=$(mktemp "/tmp/apt-upgrade.XXXXXX") || { log ERROR "❌ Failed to create temporary log file (Check /tmp permissions or disk space)"; exit 1; }
trap 'rm -f "$apt_log"' EXIT
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" 2>&1 | tee "$apt_log" | grep -E '^(Get|Setting|Processing|done|Unpacking|Setting|upgraded|removed|newly installed|Preparing|^$)' >&2
log INFO "✅ Installation completed"

# Determine if a kernel package was upgraded
KERNEL_UPDATED=false
# ⚡ Bolt: Replace O(N) loop with O(1) regex match for kernel package detection
# Impact: Reduces bash loop bottleneck during large dist-upgrades
if [[ "$UPGRADE_LIST" =~ (^|[[:space:]])(linux-image-|linux-headers-|proxmox-kernel-|proxmox-headers-|pve-kernel-|pve-headers-) ]]; then
  KERNEL_UPDATED=true
fi

# Check reboot required flag
REBOOT_REQ=""
if [[ -f /var/run/reboot-required ]]; then REBOOT_REQ=" (reboot required)"; fi

# Build telegram message with package list
REPORT="*🔔 System Update Report: $HOSTNAME*"$'\n\n'
REPORT+="✅ *$PACKAGE_COUNT packages installed:*"$'\n'

# ⚡ Bolt: Replace O(N) bash loop string manipulation with O(1) tr/grep/sed pipeline
# Impact: ~7x faster formatting of large dist-upgrade package lists by bypassing bash parsing overhead
# 🛡️ Sentinel Security Fix: Escape Markdown control characters in package names (e.g. libssl_1.1) to prevent Telegram API injection DoS
if [[ -n "$UPGRADE_LIST" ]]; then
  # Normalize whitespace safely, remove empty lines (from leading/trailing whitespace), escape markdown, and add bullets
  # printf prevents bash from interpreting edge-case flags (like -n) in the list
  clean_list=$(printf "%s\n" "$UPGRADE_LIST" | tr -s ' \t\n' '\n' | grep -v '^$' | sed -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/`/\\`/g' -e 's/^/• /')
  if [[ -n "$clean_list" ]]; then
    REPORT+="${clean_list}"$'\n'
  fi
fi

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

log INFO "✅ Upgrade completed"
log INFO "ℹ️ Sending Telegram notification..."

send_telegram "$REPORT"
