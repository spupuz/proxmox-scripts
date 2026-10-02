## 2024-10-02 - Avoid process substitution memory overhead
**Learning:** Using `<<< "$(cmd)"` creates a subshell, reads all output into memory, and then streams it. `while read ... done < <(cmd)` streams directly, which is faster and uses less memory.
**Action:** Always prefer `< <(cmd)` over `<<< "$(cmd)"` when streaming command output into a bash loop, provided the intermediate variable is not needed elsewhere.
