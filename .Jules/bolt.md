## 2024-05-19 - Pure Bash `while read` loop vs here-string overhead
**Learning:** Feeding command output to a `while read` loop via a here-string `<<< "$VAR"` incurs significant memory and string manipulation overhead, effectively reading the data into memory twice. In bash performance contexts, this adds unnecessary latency and memory pressure, particularly when parsing outputs.
**Action:** Always stream command output directly into `while read` loops using process substitution `< <(cmd)` instead of capturing it into a variable first and then using string substitution. Wait, I remember reading about a `<<< "$DISK_MSG"` in `pve-update-notifier.sh`. Let's examine that.
## 2024-05-19 - Process Substitution for streaming variables in loops
**Learning:** Capturing command output into a variable and then using a here-string (`<<< "$var"`) inside a loop causes memory overhead, because the output is loaded twice.
**Action:** When streaming command output into a loop, use process substitution (`< <(cmd)`) directly instead of intermediate variable capture and here-strings.

## 2024-05-19 - Double subshell overhead in function captures
**Learning:** Capturing the output of a command into a variable using a subshell `$(cmd)` inside a function, and then outputting it via `echo`, only to have the calling code capture the function's output in *another* subshell `$(func)` incurs the cost of two process forks.
**Action:** Stream the command output directly to standard out from within the function to eliminate the redundant inner subshell and string assignment.
