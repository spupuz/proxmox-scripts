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
| [`pve-update-notifier.sh`](pve-update-notifier.sh) | **Update Notifier**: Lightweight script that checks the PVE host and all running LXC containers for pending updates without installing them, sending a notification summary. | **Dry-Run / Audit** | PVE Host (runs globally) | **Yes** (Summary) |
| [`telegram.conf.example`](telegram.conf.example) | **Example Configuration**: Template to securely configure your Telegram Bot Token and Chat ID externally, protecting your credentials. | **Config Template** | - | - |

---

## ✨ Key Features

### 🚀 1. `lxc-updater.sh` (Auto-Updater)
* **Unattended Proxmox Host Scan:** Detects PVE host updates (using `apt-get -s upgrade`) and reports them in the Telegram message without applying them, preserving host stability.
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

### 🔔 2. `pve-update-notifier.sh` (Notifier Only)
* **Check-Only Execution:** Completely safe to run at any frequency. Performs package catalog updates (`update`) but does **not** write or upgrade packages (`dist-upgrade`/`upgrade`).
* **Quick Snapshot:** Compiles a report containing the exact number of pending updates for both the hypervisor host and every running LXC container.
* **Error Detection:** Automatically identifies and logs if an LXC lacks a standard package manager (e.g., `apt-get`).
* **Pre-flight & Timeout Protection:** Includes identical root-user and `pct` environment verification, and limits check-only container scans to a tight 60-second host-level execution timeout alongside network connection caps (10-second limit).

---

## 🛠️ Telegram Setup & Integration

Both scripts leverage the Telegram Bot API to send clean, modern markdown notifications.

### 1. Create a Telegram Bot
1. Open Telegram and search for [@BotFather](https://t.me/BotFather).
2. Start a chat and send `/newbot`.
3. Follow the prompts to name your bot and receive your **HTTP API Token** (e.g., `736052043:AAH086j...`).

### 2. Retrieve your Telegram Chat ID
1. Search for [@userinfobot](https://t.me/userinfobot) or [@raw_data_bot](https://t.me/raw_data_bot) on Telegram.
2. Send any message to get your unique user **Chat ID** (e.g., `123456789`).
3. If you want updates sent to a group, add the bot to your group and use a bot like [@raw_data_bot` to get the group's Chat ID (usually starts with a `-`, e.g., `-4098740775`).

---

## ⚙️ Configuration & Installation

### Step 1: Clone or Copy the Scripts
Place the scripts on your Proxmox Host, preferably inside `/usr/local/bin/` or a dedicated scripting directory.

```bash
mkdir -p /root/scripts
# Copy lxc-updater.sh and pve-update-notifier.sh into /root/scripts/
chmod +x /root/scripts/*.sh
```

### Step 2: Configure Secrets & Credentials (Recommended)
Rather than hardcoding your Telegram credentials inside the scripts, you can maintain them in a standalone configuration file. The scripts will automatically search for and load this file in order from:
1. The script's directory: `telegram.conf`
2. The global system path: `/etc/pve-telegram.conf`

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

### Step 3: Configure Container Exclusions & Maintenance Options
Open `lxc-updater.sh` in your editor to tweak container-specific settings:
* **`EXCLUDED_CTIDS`**: Add the container IDs (e.g., database nodes or critical servers) that should be skipped by the updater.
* **`CLEAN_TMP_7_DAYS`**: Set to `"yes"` to automatically clean up temporary files in container `/tmp` folders that are older than 7 days, conserving system disk space.

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
```

### Option B: Auto-Update Daily
For environments where staying patched immediately is a high priority:

```cron
# Run the LXC auto-updater every night at 03:00 AM
0 3 * * * /root/scripts/lxc-updater.sh >/dev/null 2>&1
```

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
