## 2024-11-20 - Standardize Emoji Prefixes for Notifications
**Learning:** In CLI/chat reports, using distinct emoji prefixes (✅, ⚠️, ❌, ⏭️) makes logs instantly scannable compared to repeating the same generic warning emoji for both skipped tasks and actual errors.
**Action:** Always map states clearly: ✅ (Success), ⚠️ (Updates Available), ❌ (Error), ⏭️ (Skipped). Refactored pve-update-notifier and system-update-notifier to enforce this pattern.
