## 2024-11-20 - Missing CLI feedback during synchronous network operations
**Learning:** Users perceived the CLI as frozen when initiating the scripts because the auto-updater performed a synchronous, blocking network request to GitHub without emitting any local CLI logs beforehand.
**Action:** Always emit a local explicit CLI log (e.g., `log INFO "ℹ️ Checking..."`) immediately before initiating long-running synchronous or blocking operations (like external API calls or package updates) to provide real-time feedback.
## 2026-09-24 - Aggregate Statistics for Batch Operations
**Learning:** Users lack a sense of scale when only individual states (updated, failed, skipped) are summarized without a grand total.
**Action:** Added a explicit "Total Containers Processed" metric to lxc-updater.sh and lxc-cleanup.sh to provide immediate accomplishment and summarize the batch scope.
## 2024-10-24 - Explicit Display of Aggregate Success Metrics
**Learning:** Even when aggregate statistics are properly calculated and appended to remote payload variables (e.g., Telegram reports), silently hiding them from the local CLI execution leaves the terminal interface feeling incomplete and deprives the user of an immediate sense of accomplishment, especially at the end of batch operations.
**Action:** Always mirror critical aggregate success metrics (like total packages installed or space freed) to standard CLI logs to provide immediate visual feedback.
## 2024-05-24 - Fast-Forward Emoji for Empty States
**Learning:** Structural empty states (e.g. "no containers") should use the fast-forward emoji (⏩️) to imply efficient, intentional bypassing of logic, while a green checkmark (✅) should be reserved for successful, completed state of actual operations.
**Action:** Used `⏩️ Total Containers Processed: 0` instead of `✅` to differentiate structural empty states from successful completions.
## 2024-05-18 - Accurate Summary Terminology
**Learning:** Using "installed" to describe `apt-get dist-upgrade` operations is misleading, as the operation primarily upgrades existing packages rather than installing new ones.
**Action:** Always use "upgraded" when summarizing the results of package upgrades to maintain accurate terminology.
