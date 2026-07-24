## 2024-05-24 - [UX Polish] Added Actionable Error Messages and English Translations
**Learning:** Language inconsistencies and generic errors create friction in CLI/Bot UX.
**Action:** Ensure all bot notifications use English consistently and add clear (e.g., 'Try using sudo') actionable paths to error messages.

## 2024-07-24 - Consistent Emojis in Status Notifications
**Learning:** Telegram bot notifications serve as the primary "UI" for this tool suite. Status inconsistencies (e.g. using `⚠️` for explicit skips, or omitting success `✅` on multi-line results) reduce scannability and conflate user intent with warnings.
**Action:** Always follow the codified status pattern for message prefixes: `✅` for Success/Done, `⚠️` for Actionable/Updates Available, `❌` for Error, `⏭️` for Skipped.
