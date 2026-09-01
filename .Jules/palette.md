## 2024-10-24 - Aligning log levels with semantic emojis
**Learning:** Mismatched emojis in CLI log outputs (e.g., using a failure emoji with an INFO level) can cause visual confusion and disrupt CLI scannability.
**Action:** Always ensure log levels align strictly with their semantic emoji prefixes (e.g., use `✅` for `INFO` when reporting zero failures).
