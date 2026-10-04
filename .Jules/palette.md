## 2024-05-24 - Initial \n**Learning:** Creating Palette UX Journal\n**Action:** Starting to record learnings
## 2024-05-24 - Zero-State Aggregates
**Learning:** Explicitly logging structural empty states (like 0 containers processed) using the fast-forward emoji (⏩️) prevents user confusion by confirming the logic was actively bypassed rather than silently failing.
**Action:** Always conditionally check aggregate counts (like `ok_count` or `clean_count`) and swap the success checkmark (✅) for the fast-forward emoji (⏩️) when the count is zero. Apply this equally to CLI logs and remote payloads.
