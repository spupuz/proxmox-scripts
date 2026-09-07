# Proxmox VE Automation & Update Scripts

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Proxmox VE](https://img.shields.io/badge/Platform-Proxmox%20VE-orange.svg)](https://www.proxmox.com)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)

A suite of production-ready, highly robust Bash automation scripts to monitor, notify, and automatically update Proxmox VE (PVE) hosts and Linux Containers (LXC). Includes multi-distribution package upgrading, interactive menu bypassing, NetBird VPN connection self-healing, and beautifully formatted Telegram status reports.

> [!WARNING]
> ### 🛑 CRITICAL DISCLAIMER: WARRANTY & LIABILITY (RELEASED "AS IS")
> **This software is released strictly "AS IS", without warranty of any kind, express or implied.** 
> Adding automation to system upgrades carries inherent risks. Operating system upgrades or containerized application updates can sometimes lead to configuration breakage, service interruption, or data corruption.
> 
> * **Backup Requirement:** You are solely responsible for ensuring complete, verified, offsite, or local backups of your Proxmox hosts and LXC container volumes **before** running these scripts.
> * **No Liability:** The authors and contributors assume absolutely no responsibility or liability for any data loss, service downtime, server crashes, hardware failures, or security issues resulting directly or indirectly from the use of this software.
> * **Read the Code:** Review the source files carefully and test them in a non-production staging environment first.

---

## 📂 Scripts Included

| Script | Purpose | Mode | Execution Target | Telegram Reports |
| :--- | :--- | :---: | :---: | :---: |
| [`lxc-updater.sh`](lxc-updater.sh) | **Full Auto-Updater**: Scans the host for updates (reports only) and executes complete, unattended package and application updates across all running LXC containers. Includes NetBird VPN checks, safety timeouts, and pre-flight checks. | **Active Upgrade** | PVE Host (runs globally) | **Yes** (Detailed) |
| [`lxc-cleanup.sh`](lxc-cleanup.sh) | **LXC Space Cleaner**: Runs a generic disk-space cleanup inside all running LXC containers (package caches, journald logs, Docker dangling objects, user caches, old `/tmp` files) and reports the space freed per container **and per cleanup step**. | **Active Cleanup** | PVE Host (runs globally) | **Yes** (Detailed) |
| [`pve-update-notifier.sh`](pve-update-notifier.sh) | **Update Notifier**: Lightweight script that checks the PVE host and all running LXC containers for pending updates without installing them, sending a notification summary. | **Dry-Run / Audit** | PVE Host (runs globally) | **Yes** (Summary) + Gotify ᶠ |
| [`system-update-notifier.sh`](system-update-notifier.sh) | **System Update Notifier**: Updates the Proxmox host system via `apt` and sends a Telegram notification with a detailed report of upgraded packages and kernel/reboot status. | **Active Upgrade** | PVE Host | **Yes** (Detailed) |
| [`telegram.conf.example`](telegram.conf.example) | **Example Configuration**: Template to securely configure your Telegram Bot Token and Chat ID externally, protecting your credentials. | **Config Template** | - | - |
| [`gotify.conf.example`](gotify.conf.example) | **Example Configuration**: Template to securely configure your Gotify server URL and application token externally, protecting your credentials. | **Config Template** | - | - |

_ᶠ Gotify is a self-hosted push-notification alternative to Telegram, supported only by `pve-update-notifier.sh` — see [Gotify Setup](#gotify-setup--integration). It sends to Telegram and/or Gotify depending on which config file(s) are present._

---

## ✨ Key Features

### 🔄 0. Auto-Update from GitHub (All Scripts)
* **Disabled by Default:** Auto-update is **off** by default (`AUTO_UPDATE="no"`) to protect against compromised repositories pushing malicious code.
* **Manual Update via `--update`:** Each script supports a `--update` flag that downloads the latest version from GitHub and then **continues with its main purpose**:
  ```bash
  ./lxc-updater.sh --update        # updates the scripts, then updates LXC containers
  ./lxc-cleanup.sh --update        # updates the scripts, then cleans LXC containers
  ./pve-update-notifier.sh --update # updates the scripts, then checks for updates
  ./system-update-notifier.sh --update # updates the scripts, then upgrades the host
  ```
  If a new version is found, it downloads it, backs up the old one (`.bak`), and re-executes automatically. If already up to date, it prints the current version and proceeds with its normal operation.
* **One Command Updates All Four:** Since all scripts are released with the same version, running `--update` on *any* one of them also updates the other three scripts installed in the same directory (each replaced one is backed up as `.bak`). Scripts not present in that directory are skipped with an informational log message.
* **Secure Version Parsing:** Version strings are sanitized by stripping all non-numeric characters before arithmetic evaluation, preventing potential command injection from manipulated GitHub responses.
* **Seamless Update:** If a newer version is available, the script downloads it, backs up the current version (`.bak`), replaces itself, and re-executes automatically.
* **Offline Resilient:** If GitHub is unreachable (network issues, firewalls, air-gapped environments), the script proceeds with the current version without errors.
* **Safe by Default:** Downloaded files are validated (shebang check) before replacing the current script. Failed downloads are cleaned up and the current version continues to run. Never downgrades to an older version.
* **Enable Auto-Update:** Set `AUTO_UPDATE="yes"` in the script or via environment variable `AUTO_UPDATE=yes` to re-enable automatic updates on every run.

### 🚀 1. `lxc-updater.sh` (Auto-Updater)
* **Unattended Proxmox Host Scan:** Detects PVE host updates (using `apt-get -s upgrade`) and reports them in the Telegram message without applying them, preserving host stability.
* **Auto-Detect PVE Host:** Automatically detects if running on a Proxmox host by checking for the `pct` command. If not present, LXC-related checks are skipped gracefully.
* **Batched Environment Detection:** Performs container environment detection (package manager, app commands, NetBird status) in a single `pct exec` call instead of spawning up to 10 processes per container, reducing latency by ~90%.
* **Smart App-Updater Integrations:** Searches inside each LXC for common application update scripts (e.g., [Proxmox Helper Scripts by tteck](https://community-scripts.github.io/ProxmoxVE/) or custom bash updates like `/root/update.sh` or `/usr/local/bin/update`).
* **Interactive Prompt Bypass:** Injects temporary `whiptail` and `clear` command mockups, and exports environment variables (`DEBIAN_FRONTEND=noninteractive`, `verbose=1`, `var_unattended=yes`, etc.) to force interactive scripts into executing in a fully unattended, verbose mode without hanging.
* **Comprehensive Multi-Distro OS Upgrades & Cleanup:** Falls back to or complements app updates by running native package manager updates inside the containers, supporting:
  * **Debian/Ubuntu:** `apt-get` (with standard dpkg option overrides `-o Dpkg::Options::="--force-confold"` to avoid prompt blocks + `autoremove` + `clean` package cache cleanup).
  * **Alpine Linux:** `apk` (`update && upgrade`).
  * **Fedora/RHEL/CentOS:** `dnf` or `yum`.
* **Automated `/tmp` Directory Cleanup:** Automatically scans and deletes files/directories in the container's `/tmp` older than 7 days to conserve disk space, configurable via script variables.
* **NetBird VPN Resilience:** Checks for the presence of NetBird inside containers. If NetBird is disconnected, it attempts to bring the interface up (`netbird up`) and reports the container's NetBird IP address.
* **Exclusion List:** Easily skip specific container IDs (e.g., database nodes or critical proxies) by adding their CTID to the `EXCLUDED_CTIDS` array.
* **Pre-flight Safety Checks:** Automatically verifies the script is executed by the `root` user (UID 0) and that the Proxmox Virtual Environment container command (`pct`) is present before carrying out any actions.
* **Fail-Safe Execution Timeouts:** Wraps all inner container calls with a host-level execution `timeout` (5 minutes) and enforces quick network timeouts on all `apt-get` connections (10 seconds, 1 retry) to prevent broken or unresponsive containers from hanging the entire automation chain.

### 🧹 2. `lxc-cleanup.sh` (Space Cleaner)
* **Generic In-Container Cleanup:** Runs a single generic cleanup script inside every running LXC via `pct exec` and reports the space freed on the container's `/` filesystem, with a per-step breakdown (package cache, logs, Docker, user caches, `/tmp`).
* **Package Manager Caches:** Cleans `apt` (`autoremove --purge` + `clean` + `/var/lib/apt/lists`), `apk` (`cache clean`), `dnf` and `yum` (`clean all`), depending on what the container uses.
* **System Logs:** Vacuums journald logs down to a configurable size (`JOURNAL_VACUUM_SIZE`, default `50M`) and max age (7 days) when `journalctl` is present.
* **Docker (Optional):** If Docker is installed inside a container, prunes dangling images and build cache (`image/builder prune -f`). Orphaned volume pruning is **opt-in** via `CLEAN_DOCKER_VOLUME_PRUNE` (default `no`) because it deletes all volumes not attached to a container.
* **Docker Containers `/tmp` (Optional):** If Docker is installed inside a container, also deletes files older than 7 days from the `/tmp` of every running Docker container (their writable layers), e.g. abandoned temp files left by apps like subsyncarr.
* **User Caches:** Removes regenerable user caches (`~/.cache/*`, npm `_cacache`, pnpm store, Go module cache) for root and all `/home` users.
* **Old `/tmp` Files:** Deletes files/directories in the container's `/tmp` older than 7 days.
* **Fully Configurable:** Each cleanup category can be toggled independently (`CLEAN_PKG_CACHE`, `CLEAN_JOURNAL`, `CLEAN_DOCKER`, `CLEAN_DOCKER_VOLUME_PRUNE`, `CLEAN_DOCKER_TMP`, `CLEAN_USER_CACHE`, `CLEAN_OLD_TMP`).
* **Exclusion List & Safety:** Skips containers listed in `EXCLUDED_CTIDS` and includes the same root/`pct` pre-flight checks and per-container execution timeouts as the other scripts.

### 🔔 3. `pve-update-notifier.sh` (Notifier Only)
* **Check-Only Execution:** Completely safe to run at any frequency. Performs package catalog updates (`update`) but does **not** write or upgrade packages (`dist-upgrade`/`upgrade`).
* **Auto-Detect PVE Host:** Automatically detects if running on a Proxmox host by checking for the `pct` command. If not present, only host-level checks are performed.
* **Quick Snapshot:** Compiles a report containing the exact number of pending updates for both the hypervisor host and every running LXC container.
* **Error Detection:** Automatically identifies and logs if an LXC lacks a standard package manager (e.g., `apt-get`).
* **Telegram & Gotify Notifications:** Sends the summary report to Telegram and/or a self-hosted [Gotify](https://gotify.net) server. Gotify activates automatically when `gotify.conf` is present — no extra flags (see [Gotify Setup](#gotify-setup--integration)).
* **Pre-flight & Timeout Protection:** Includes identical root-user and `pct` environment verification, and limits check-only container scans to a tight 60-second host-level execution timeout alongside network connection caps (10-second limit).

---

## 🔖 Versioning & Releases

All scripts share the same version number via the `SCRIPT_VERSION` variable (e.g. `SCRIPT_VERSION="v0.0.1"`).

### How It Works
1. **Edit** `SCRIPT_VERSION` in all four `.sh` files (they must match)
2. **Push** to `main` — the GitHub Actions workflow automatically:
   - Reads the version from the scripts
   - Creates a Git tag (e.g. `v0.0.2`)
   - Publishes a GitHub Release with the `.sh` files attached
3. **Users** update manually via `./<script> --update` (updates all four scripts, then runs the script)

### Version Format
Follow [Semantic Versioning](https://semver.org/): `vMAJOR.MINOR.PATCH`
- **PATCH** — bug fixes, small tweaks
- **MINOR** — new features, backward-compatible
- **MAJOR** — breaking changes

### Example Release Flow
```bash
# 1. Update version in all scripts
SCRIPT_VERSION="v0.0.2"  # in lxc-updater.sh, lxc-cleanup.sh, pve-update-notifier.sh, system-update-notifier.sh

# 2. Commit and push
git add *.sh
git commit -m "bump version to v0.0.2"
git push origin main

# 3. GitHub Actions creates the release automatically
```

---

## 🛠️ Telegram Setup & Integration

All scripts leverage the Telegram Bot API to send clean, modern markdown notifications.

### 1. Create a Telegram Bot
1. Open Telegram and search for [@BotFather](https://t.me/BotFather).
2. Start a chat and send `/newbot`.
3. Follow the prompts to name your bot and receive your **HTTP API Token** (e.g., `736052043:AAH086j...`).

### 2. Retrieve your Telegram Chat ID
1. Search for [@userinfobot](https://t.me/userinfobot) or [@raw_data_bot](https://t.me/raw_data_bot) on Telegram.
2. Send any message to get your unique user **Chat ID** (e.g., `123456789`).
3. If you want updates sent to a group, add the bot to your group and use a bot like [@raw_data_bot](https://t.me/raw_data_bot) to get the group's Chat ID (usually starts with a `-`, e.g., `-4098740775`).

## 🔔 Gotify Setup & Integration

[`pve-update-notifier.sh`](pve-update-notifier.sh) can send its report to a **self-hosted Gotify** server instead of (or in addition to) Telegram. Gotify is a lightweight push-notification server — notifications arrive in real-time when your phone is on the local network, and sync when you reconnect.

> [!IMPORTANT]
> **Gotify is a secondary notification channel — Telegram is the primary one.** The notification function always calls Telegram first, so `telegram.conf` should be configured *before* you set up Gotify. If Telegram is not configured, the script logs a warning and continues, but following the intended order avoids surprises.

### 1. Install Gotify
You can install Gotify as an LXC container using the [community-scripts](https://community-scripts.github.io/ProxmoxVE/) installer:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/gotify.sh)"
```
Or run it with Docker on any existing host:
```bash
docker run -d --name gotify --restart unless-stopped \
  -p 80:80 \
  -v "$PWD/gotify-data:/data" \
  gotify/server
```
See [gotify.net](https://gotify.net) for all installation options.

### 2. First Login & Secure the Server
1. Open the Gotify web UI (e.g., `http://<gotify-ip>:80`).
2. Log in with the default credentials (`admin` / `admin`).
3. **Immediately change the admin password** in **Settings** — this password is not needed by the scripts, but must be secured.

### 3. Create an Application & Get a Token
1. Go to **Apps → Create Application**.
2. Give it a name (e.g., `Proxmox`) — the description/icon are optional.
3. Click **Create**: Gotify generates an **application token** (a long random string). Copy it — you will put it in `gotify.conf`.

### 4. Configure the Script
1. Copy the example config next to the scripts (or to `/etc/pve-gotify.conf`):
   ```bash
   cp gotify.conf.example gotify.conf
   ```
2. Edit `gotify.conf` and fill in your server URL and the application token:
   ```bash
   # gotify.conf
   GOTIFY_SERVER="http://gotify.lan:80"
   GOTIFY_TOKEN="your_gotify_app_token"
   ```
   > For a remote (internet-exposed) server always use `https://` — the script then enforces TLSv1.2+ automatically.
3. Restrict file permissions (contains a secret):
   ```bash
   chmod 600 gotify.conf
   ```

### 5. Verify It Works
Run the notifier once and check it logs `✅ Gotify delivery successful`:
```bash
./pve-update-notifier.sh
```
If something is wrong you'll see `❌ Gotify Error:` with the server response (check the URL or token).

You can also probe the server/token directly from your PVE host:
```bash
curl -X POST "http://<gotify-ip>/message?token=<token>" \
  -F "title=Proxmox Test" -F "message=Hello from the PVE host!" -F "priority=5"
```
You should receive the push notification on your phone instantly.

---

## ⚙️ Configuration & Installation

### Step 1: Clone or Copy the Scripts
Place the scripts on your Proxmox Host, preferably inside `/usr/local/bin/` or a dedicated scripting directory.

```bash
mkdir -p /root/scripts
# Copy lxc-updater.sh, lxc-cleanup.sh, pve-update-notifier.sh, and system-update-notifier.sh into /root/scripts/
chmod +x /root/scripts/*.sh
```

> [!TIP]
> **Manual Updates:** Auto-update is disabled by default for security. Use `./<script> --update` to pull the latest version from GitHub. This updates all four scripts in the same directory and then runs the script's normal operation.

### Step 2: Configure Secrets & Credentials (Recommended)
Rather than hardcoding your Telegram credentials inside the scripts, you can maintain them in a standalone configuration file. The scripts will automatically search for and load this file in order from:
1. The script's directory: `telegram.conf`
2. The global system path: `/etc/pve-telegram.conf`

If credentials are not found, an actionable error message will indicate exactly where to set them.

To configure this:
1. Copy the example configuration file:
   ```bash
   cp telegram.conf.example telegram.conf
   ```
2. Open `telegram.conf` and populate it with your actual Bot Token and Chat ID:
   ```bash
   # telegram.conf
   TOKEN="your_telegram_bot_token"
   CHAT_ID="your_telegram_chat_id"
   ```
3. Set secure permissions on the file to prevent other system users from reading it:
   ```bash
   chmod 600 telegram.conf
   ```

> [!IMPORTANT]
> **Security Notice:** The `.gitignore` file included in this repository will automatically prevent you from accidentally committing your active `telegram.conf` file to Git! Never publish your actual Telegram bot token or Chat ID to public repositories.

### Gotify Configuration (Optional)
Only `pve-update-notifier.sh` uses Gotify. Rather than hardcoding the credentials inside the script, you can maintain them in a standalone configuration file. The script automatically searches for and loads this file in order from:
1. The script's directory: `gotify.conf`
2. The global system path: `/etc/pve-gotify.conf`

If credentials are not found, the script logs `⏩️ Gotify config missing` and simply keeps using Telegram (no error).

To configure this:
1. Copy the example configuration file:
   ```bash
   cp gotify.conf.example gotify.conf
   ```
2. Open `gotify.conf` and populate it with your server URL and application token:
   ```bash
   # gotify.conf
   GOTIFY_SERVER="http://gotify.lan:80"
   GOTIFY_TOKEN="your_gotify_app_token"
   ```
3. Set secure permissions on the file to prevent other system users from reading it:
   ```bash
   chmod 600 gotify.conf
   ```

> [!NOTE]
> If both `telegram.conf` and `gotify.conf` are configured, `pve-update-notifier.sh` sends the report to **both** channels. If only one is configured, only that one receives notifications. No extra flags needed. Since Gotify is plain-text, Markdown formatting (asterisks, backticks) is stripped before sending.

### Step 3: Configure Container Exclusions & Maintenance Options
Open `lxc-updater.sh` in your editor to tweak container-specific settings:
* **`EXCLUDED_CTIDS`**: Add the container IDs (e.g., database nodes or critical servers) that should be skipped by the updater.
* **`CLEAN_TMP_7_DAYS`**: Set to `"yes"` to automatically clean up temporary files in container `/tmp` folders that are older than 7 days, conserving system disk space.

Open `lxc-cleanup.sh` to tweak the standalone cleanup options:
* **`EXCLUDED_CTIDS`**: Add the container IDs that should be skipped by the cleaner.
* **`CLEAN_PKG_CACHE`**, **`CLEAN_JOURNAL`**, **`CLEAN_DOCKER`**, **`CLEAN_DOCKER_VOLUME_PRUNE`**, **`CLEAN_DOCKER_TMP`**, **`CLEAN_USER_CACHE`**, **`CLEAN_OLD_TMP`**: Independently toggle each cleanup category (`"yes"`/`"no"`). `CLEAN_DOCKER_VOLUME_PRUNE` defaults to `"no"` (it deletes all volumes not attached to a container).
* **`JOURNAL_VACUUM_SIZE`**: Maximum journald log size to keep (default `50M`).

### Step 4: Update Scripts
Auto-update is disabled by default to protect against compromised repositories. Use the `--update` flag to manually update any script. Since all scripts share the same version, running `--update` on any one of them updates **all four** scripts installed in the same directory and then **continues with the script's normal operation**:

```bash
# Updates all four scripts, then updates LXC containers
./lxc-updater.sh --update

# Updates all four scripts, then cleans LXC containers
./lxc-cleanup.sh --update

# Updates all four scripts, then checks for updates and notifies
./pve-update-notifier.sh --update

# Updates all four scripts, then upgrades the host system
./system-update-notifier.sh --update
```

> [!IMPORTANT]
> **Why is auto-update disabled by default?**
> If an attacker gains write access to this repository, they could inject malicious code into the scripts. With auto-update enabled, that code would execute automatically on all your Proxmox hosts. By keeping auto-update disabled, you control exactly when and which version is deployed.

To re-enable automatic updates on every run (not recommended unless you trust the source):
```bash
export AUTO_UPDATE=yes
/root/scripts/lxc-updater.sh
```

Or set it in crontab:
```cron
AUTO_UPDATE=yes 0 2 * * 0 /root/scripts/lxc-updater.sh >/dev/null 2>&1
```

### Step 5: Manual Script Update via curl (Alternative)
If you prefer not to use the `--update` flag, you can manually download and replace scripts. This also only updates the files and does not run any script logic:

```bash
LATEST=$(curl -s https://api.github.com/repos/spupuz/proxmox-scripts/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')

for script in lxc-updater.sh lxc-cleanup.sh pve-update-notifier.sh system-update-notifier.sh; do
  curl -sL -o "/root/scripts/${script}" "https://raw.githubusercontent.com/spupuz/proxmox-scripts/${LATEST}/${script}"
  chmod +x "/root/scripts/${script}"
done
echo "All scripts updated to ${LATEST}"
```

---

## ⏰ Cron Scheduling (Automation)

To run these scripts automatically, add them to your Proxmox Host’s cron jobs.

Open the system crontab editor:
```bash
crontab -e
```

Add your desired schedules. Below are some recommended configurations:

### Option A: Check and Notify Daily, Auto-Update Weekly
This is the recommended setup to stay informed daily, but delay actual automated updates to a weekend maintenance window.

```cron
# Send a check-only notification every morning at 08:00 AM
0 8 * * * /root/scripts/pve-update-notifier.sh >/dev/null 2>&1

# Run the complete LXC auto-updater every Sunday at 02:00 AM
0 2 * * 0 /root/scripts/lxc-updater.sh >/dev/null 2>&1

# Run the LXC space cleaner every night at 03:30 AM
30 3 * * * /root/scripts/lxc-cleanup.sh >/dev/null 2>&1

# Update host system and notify every Saturday at 04:00 AM
0 4 * * 6 /root/scripts/system-update-notifier.sh >/dev/null 2>&1
```

### Option B: Auto-Update Daily
For environments where staying patched immediately is a high priority. This requires `AUTO_UPDATE=yes` to be set:

```cron
# Run the LXC auto-updater every night at 03:00 AM
0 3 * * * AUTO_UPDATE=yes /root/scripts/lxc-updater.sh >/dev/null 2>&1

# Update host system every night at 04:00 AM
0 4 * * * AUTO_UPDATE=yes /root/scripts/system-update-notifier.sh >/dev/null 2>&1
```

---

## ☕ Support the Project

If you find these scripts useful and they help you keep your Proxmox environment up to date, consider buying me a coffee to support ongoing development and maintenance. Every little bit is greatly appreciated!

<a href="https://www.buymeacoffee.com/spupuz" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy me a coffee" style="height: 60px !important; width: 217px !important;" ></a>

[Buy me a coffee](https://www.buymeacoffee.com/spupuz)

---

## 📜 License & Warranty

This project is licensed under the terms of the **MIT License**.

```
Copyright (c) 2026 Belloni Alessandro

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

See the [LICENSE](LICENSE) file for the full text.
