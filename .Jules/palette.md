## 2024-10-09 - Distinct UI Semantics for "Empty" vs "Excluded" States
**Learning:** Initially, we conflated structural empty states (like "no containers found" or "Total Space Freed: 0 B") with explicit user exclusion states by using the same skip track emoji (`⏭️`) for both. However, empty states represent an intentional, efficient bypassing of logic, while exclusions indicate a user-directed override.
**Action:** Use the fast-forward emoji (`⏩`) to represent structural, zero-value aggregates and empty states. Reserve the skip track emoji (`⏭️`) exclusively for items explicitly skipped due to configuration.

## 2023-10-15 - [Use package emoji for packages upgraded]
**Learning:** The package (📦) emoji is standard for package upgrade totals, but it was not being used consistently across all scripts.
**Action:** Update the success state for `Total packages upgraded` in `system-update-notifier.sh` to use the 📦 emoji, ensuring consistency with package processing logging in other scripts.
