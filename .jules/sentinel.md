## 2026-07-21 - [Insecure Temporary Files in Shell Scripts]
**Vulnerability:** Shell scripts using static or predictable paths for temporary files (e.g., `/tmp/${script_name}.new`).
**Learning:** This exposes the system to symlink attacks, allowing local privilege escalation, especially for scripts running with elevated (root) privileges as in this repository.
**Prevention:** Always use `mktemp` (e.g., `tmp_file=$(mktemp "/tmp/script.XXXXXX")`) to create temporary files in shell scripts.
