## 2024-05-18 - Caching Proxmox CLI tools outside loops
**Learning:** Calling Proxmox CLI tools (e.g., `pct list`, `pct config`) inside bash loops causes severe O(N) latency because it repeatedly spawns heavy processes. This is a codebase-specific performance pattern to watch out for.
**Action:** Always batch or cache the output of these tools outside the loop and parse the cache (e.g. using `awk` or `grep`) instead of making repeated CLI calls inside the loop.
