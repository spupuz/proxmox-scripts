## 2023-10-24 - [Prevent path expansion during unquoted bash formatting]
**Vulnerability:** Globbing vulnerability in `system-update-notifier.sh` when formatting space-separated lists in Bash.
**Learning:** Using `printf -v` to format unquoted variables (like `$UPGRADE_LIST`) triggers pathname expansion (globbing) if the variable contains wildcards (`*`, `?`), leading to unintended directory content disclosure.
**Prevention:** Always temporarily disable globbing (`set -f`) before expanding unquoted variables for multi-line formatting, and re-enable it (`set +f`) immediately after.
