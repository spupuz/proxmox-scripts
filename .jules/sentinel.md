## 2024-05-18 - Insecure Temporary File Creation
**Vulnerability:** Predictable temporary files in `/tmp` (e.g. `/tmp/script.sh.new`) were used to download script updates. Since these scripts run as root, this allowed for symlink attacks and local privilege escalation.
**Learning:** Shell scripts downloading remote payloads must use `mktemp` to generate secure, unpredictable temporary files to prevent symlink attacks in world-writable directories.
**Prevention:** Always use `mktemp` to create temporary files in bash scripts running with elevated privileges.
