## 2026-07-24 - [Proxmox CLI Execution Overhead]
**Learning:** Calling Proxmox CLI tools (e.g., `pct exec`, `pct list`) inside bash loops or conditionally invoking them multiple times incurs severe O(N) latency because spawning these heavy processes is slow.
**Action:** Always batch related commands (like conditional status checks and recoveries) into a single script passed to `pct exec` rather than calling `pct exec` multiple times.
