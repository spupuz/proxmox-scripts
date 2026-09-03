## 2026-09-03 - Redundant Grep in Awk Pipelines
**Learning:** Using `grep` before `awk` (e.g. `grep -E '^Inst' | awk '{print $2}'`) is a redundant bash anti-pattern. Awk is fully capable of pattern matching itself (e.g. `awk '/^Inst / {print $2}'`), so adding `grep` only serves to spawn an unnecessary extra sub-process fork, slightly degrading performance on large outputs like `apt-get -s dist-upgrade`.
**Action:** Replace `grep | awk` pipelines with pure `awk` conditionals (e.g. `/pattern/ {action}`).
