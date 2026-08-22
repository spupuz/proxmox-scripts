## 2026-08-22 - Bash Background Job Logging UX Pattern
**Learning:** When executing background jobs with output buffered to files via subshells in Bash, real-time visual feedback is lost, making the CLI interface appear to hang during long-running parallel tasks.
**Action:** Duplicating the standard output to a new file descriptor (e.g., `exec 3>&1`) before the loop allows specific subshell commands to write directly back to the terminal (e.g., `>&3`) in real-time, providing immediate state visibility while preserving the overall output buffering.
