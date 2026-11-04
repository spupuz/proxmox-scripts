## 2024-11-04 - Fix Bash Arithmetic Evaluation Octal DoS
**Vulnerability:** External script outputs (like container updates or space freed) containing values like "08" or "09" crash the bash script and cause Denial of Service when evaluated via `((var += val))` because bash misinterprets them as invalid octal numbers.
**Learning:** Bash's arithmetic evaluation `(( ))` interprets any number starting with `0` as octal, breaking on 08 and 09. Untrusted input parsed from logs or APIs can accidentally contain these leading zeroes.
**Prevention:** Always enforce base-10 parsing by prefixing variables with `10#` inside arithmetic evaluation contexts: `(( var += 10#$val ))`.
