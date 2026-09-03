## 2024-05-24 - Avoid false-positive failure emojis in remote payloads
**Learning:** Hardcoding error emojis (like `❌`) in notification payloads for zero-count metrics causes unnecessary user alarm.
**Action:** Always conditionally align the payload emoji to match the local CLI log level and the true metric state (e.g., `✅ Failed: 0`).
