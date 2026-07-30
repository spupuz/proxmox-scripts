
## 2024-05-18 - Actionable Error Feedback
**Learning:** Silent failures and generic error states in CLI tools often lead to a false sense of security (e.g., falsely reporting a system as up-to-date) and leave users without clear troubleshooting paths.
**Action:** Pair all generic error states in CLI outputs and notifications with immediate, actionable hints (e.g., "Check network or apt locks", "Container offline or timed out") to minimize user friction and confusion.
