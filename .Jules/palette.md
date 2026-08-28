## 2024-05-18 - Missing CLI empty state logging
**Learning:** Found that when looping through updates or operations, empty states were not logged to the local CLI visibly, but only added to remote payloads.
**Action:** Always provide explicit CLI logging (e.g., `log INFO "⏭️ No running containers found."`) for empty states and don't solely append empty state messages to remote payload variables.

## 2024-05-18 - Concurrent UX Mirroring Garbled Output
**Learning:** Found that using the `>&3` log mirroring pattern directly inside a concurrently executing background subshell bypasses file-based buffering, causing output to interleave and become garbled on the terminal.
**Action:** When printing background logs synchronously to the screen, always buffer them into a temporary file first, and only execute the `log ... >&3` logic sequentially in the main process loop after jobs complete, ensuring terminal outputs do not overlap.
