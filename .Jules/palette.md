## 2025-02-18 - Unified Logging & Emoji Prefixes
**Learning:** Sequential `log` and `echo` calls for CLI formatting create disjointed syslog entries without context or visual scannability.
**Action:** Replaced `echo` with the unified `log()` function and embedded emoji prefixes directly within the log payload to ensure consistent UX across terminal and remote logs.
