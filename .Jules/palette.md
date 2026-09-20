## 2026-09-20 - [Real-time Feedback for Buffered Asynchronous Jobs]
**Learning:** When batching background jobs that buffer their logs until completion (e.g., Docker-build style output), the CLI can appear completely frozen for long periods. Real-time feedback must be provided immediately upon spawning the job to signal activity.
**Action:** Always emit a local explicit CLI log (e.g., 'Starting...') immediately before initiating long-running or buffered subshells to prevent the interface from appearing silent.
