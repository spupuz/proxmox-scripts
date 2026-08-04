## 2023-10-27 - Centralized Logging for UX consistency
**Learning:** Sequential `log` and `echo >&2` for outputting lists causes disjointed console output and misses capturing lists in syslogs.
**Action:** Always pipe user-facing list output through the centralized `log()` function by merging them inside variables, appending visual list elements directly inside the single log payload.
