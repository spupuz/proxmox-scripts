## 2023-10-03 - Empty State Aggregates
**Learning:** Aggregate statistics that result in a zero value (e.g., "Updated: 0" or "Cleaned: 0") represent structural empty states where operations were intentionally bypassed or no work was performed. They should not use the success checkmark (✅) unless they represent a lack of errors (e.g., "Failed: 0").
**Action:** Always use the fast-forward emoji (⏩️) for zero-value aggregates to imply efficient, intentional bypassing of logic and differentiate from completed operations.

## 2024-10-05 - Fix false-positive success emojis on zero-value aggregates
**Learning:** Aggregate statistics that result in a zero value (e.g., 'Total Space Freed: 0 B', 'Total Pending Updates: 0') represent structural empty states where operations were intentionally bypassed, not completed operations. Use the fast-forward emoji (⏩️) for these zero-value aggregates instead of a green checkmark (✅).
**Action:** Always add conditional logic to use the fast-forward emoji (⏩️) when aggregate counts (like `ok_count`, `clean_count`, `skip_count`) are zero instead of silently hiding them or emitting false-positive success emojis (✅) or skip emojis (⏭️).

## 2024-10-06 - Explicit logging for blocking network requests
**Learning:** Background network requests like Telegram API calls without immediate prior CLI logging cause the interface to appear frozen at the end of execution, leading to user uncertainty about whether the script has completed or hung.
**Action:** Always provide an immediate explicit CLI log (e.g., `log INFO "ℹ️ Sending report to Telegram..."`) before initiating blocking network requests like remote notifications, to provide real-time feedback.
