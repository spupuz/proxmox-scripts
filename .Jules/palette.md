## 2024-11-20 - Missing CLI feedback during synchronous network operations
**Learning:** Users perceived the CLI as frozen when initiating the scripts because the auto-updater performed a synchronous, blocking network request to GitHub without emitting any local CLI logs beforehand.
**Action:** Always emit a local explicit CLI log (e.g., `log INFO "ℹ️ Checking..."`) immediately before initiating long-running synchronous or blocking operations (like external API calls or package updates) to provide real-time feedback.
## 2026-09-24 - Aggregate Statistics for Batch Operations
**Learning:** Users lack a sense of scale when only individual states (updated, failed, skipped) are summarized without a grand total.
**Action:** Added a explicit "Total Containers Processed" metric to lxc-updater.sh and lxc-cleanup.sh to provide immediate accomplishment and summarize the batch scope.
## 2024-10-24 - Explicit Display of Aggregate Success Metrics
**Learning:** Even when aggregate statistics are properly calculated and appended to remote payload variables (e.g., Telegram reports), silently hiding them from the local CLI execution leaves the terminal interface feeling incomplete and deprives the user of an immediate sense of accomplishment, especially at the end of batch operations.
**Action:** Always mirror critical aggregate success metrics (like total packages installed or space freed) to standard CLI logs to provide immediate visual feedback.
