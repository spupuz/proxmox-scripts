## 2024-11-20 - Missing CLI feedback during synchronous network operations
**Learning:** Users perceived the CLI as frozen when initiating the scripts because the auto-updater performed a synchronous, blocking network request to GitHub without emitting any local CLI logs beforehand.
**Action:** Always emit a local explicit CLI log (e.g., `log INFO "ℹ️ Checking..."`) immediately before initiating long-running synchronous or blocking operations (like external API calls or package updates) to provide real-time feedback.
## 2026-09-24 - Aggregate Statistics for Batch Operations
**Learning:** Users lack a sense of scale when only individual states (updated, failed, skipped) are summarized without a grand total.
**Action:** Added a explicit "Total Containers Processed" metric to lxc-updater.sh and lxc-cleanup.sh to provide immediate accomplishment and summarize the batch scope.
## 2024-05-18 - Accurate Summary Terminology
**Learning:** Using "installed" to describe `apt-get dist-upgrade` operations is misleading, as the operation primarily upgrades existing packages rather than installing new ones.
**Action:** Always use "upgraded" when summarizing the results of package upgrades to maintain accurate terminology.
