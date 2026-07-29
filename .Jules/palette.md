## 2024-05-24 - Actionable Errors & Visual Anchors
**Learning:** Generic error messages (e.g., "Error checking updates") cause user confusion. Furthermore, logs and reports without standard visual anchors (emojis) are hard to scan.
**Action:** Pair all generic error states with immediate, actionable hints (e.g., "Check network or apt locks"). Enforce a strict emoji prefix standard (✅ for success, ⚠️ for warnings, ❌ for errors, ⏭️ for skipped) across all CLI outputs and Telegram notifications for rapid visual parsing.
