## 2024-07-20 - Batching Proxmox CLI Tools (pct)
**Learning:** Calling Proxmox CLI tools (`pct list`, `pct config`) inside a bash loop introduces significant latency, as each execution spawns a heavy process, slowing down scripts immensely when managing multiple containers.
**Action:** Always batch CLI commands. Cache the output of lists (like `pct list`) outside the loop, or parse both ID and Name in a single pass to eliminate O(N) CLI calls inside loops.
