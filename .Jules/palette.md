
## 2023-10-24 - Mirror remote UI state to local CLI
**Learning:** When building CLI tools that also send remote notifications (e.g. Telegram reports), leaving the local CLI completely silent during critical warnings (like high disk usage) creates a poor empty-state experience for the user sitting at the terminal.
**Action:** Always mirror critical payload states and warnings to standard `log` calls to provide immediate visual feedback in the CLI interface, parsing and stripping formatting where necessary.
