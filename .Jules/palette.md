## 2024-09-14 - UX/Logging Constraint Emoji Matching
**Learning:** Conditional emoji logic for summary statistics (like failure counts) should update both the CLI logs and remote notification payloads.
**Action:** Always ensure `$report` variable modifications align with log level emojis in summary blocks (e.g. `report+="✅ Failed: 0"` when `fail_count` is 0).

## 2024-09-14 - Aggregate Metrics in Notification Summaries
**Learning:** Raw lists of items (like container update statuses) in notification payloads lack immediate scannability. Users have to manually parse the list to understand the overall system state.
**Action:** Always append an aggregate summary block (e.g., total ok, warn, fail counts) at the end of batch status reports to provide immediate, actionable value.
