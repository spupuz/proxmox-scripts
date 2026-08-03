## 2026-08-03 - [Console Output UX] Unified Logging with Embedded Emojis
**Learning:** Hardcoded `echo` statements bypass standard unified logging methods, resulting in missing syslog entires and unformatted CLI output. Furthermore, utilizing `echo` concurrently or right next to unified logging (like `log()`) leads to duplicate messages in the UX flow.
**Action:** Pipe all user-facing information through a central `log()` (or equivalent wrapper) function. Enhance scannability by embedding emoji states (✅, ❌, ⚠️) directly inside the log payload instead of printing them independently.
