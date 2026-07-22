## 2024-05-24 - Batching Process Execution in LXC Loop
**Learning:** Calling Proxmox CLI tools (e.g., `pct exec`) repeatedly inside a bash loop creates severe O(N) latency due to the heavy overhead of repeatedly spawning processes for each container.
**Action:** Always batch operations inside a single `pct exec` or `pct` command when querying or manipulating data across multiple containers in a loop to reduce process-spawning overhead.
