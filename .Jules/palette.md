## 2024-11-20 - Missing CLI feedback during synchronous network operations
**Learning:** Users perceived the CLI as frozen when initiating the scripts because the auto-updater performed a synchronous, blocking network request to GitHub without emitting any local CLI logs beforehand.
**Action:** Always emit a local explicit CLI log (e.g., `log INFO "ℹ️ Checking..."`) immediately before initiating long-running synchronous or blocking operations (like external API calls or package updates) to provide real-time feedback.
