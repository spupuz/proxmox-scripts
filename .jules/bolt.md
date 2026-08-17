## $(date +%Y-%m-%d) - Proxmox Config Read Optimization
**Learning:** Calling `pct config <ctid>` inside loops spawns a heavy Perl process per container, causing severe O(N) latency.
**Action:** Replace `pct config` calls with a direct file read of `/etc/pve/lxc/${ctid}.conf`. To properly replicate `pct config`'s behavior of ignoring snapshots and pending states, ensure the reading loop breaks when encountering section header brackets (e.g., `[[ "$line" == \[* ]] && break`), ensuring the `[` is properly escaped to prevent bash syntax errors.

## $(date +%Y-%m-%d) - Bash Parsing vs Compiled Utilities
**Learning:** Replacing clean, 1-line `awk`, `grep`, or `sed` pipelines with multi-line pure Bash `while read` loops when processing large, single text outputs (e.g., from `pct list` or `apt-get`) is an anti-pattern. Compiled C utilities are heavily optimized and significantly faster for non-trivial text sizes than Bash's line-by-line interpreter.
**Action:** Retain external tools for bulk text processing unless the command is executed repeatedly in a tight loop where process spawning overhead dominates.
