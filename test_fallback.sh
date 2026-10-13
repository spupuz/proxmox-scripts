#!/bin/bash
awk_cmd() {
    echo "output" | awk '{print $1}'
}

# The original has:
# HOST_UPDATES=$(awk_cmd)
# echo "${HOST_UPDATES:-0}"
# If awk outputs nothing, HOST_UPDATES is empty, so it prints 0.

# If we just run the awk_cmd directly, and it outputs nothing, it will just output nothing.
# We need to make awk output 0 if no match is found.
# But wait, the original awk command already has:
# awk '/^[0-9]+ upgraded/ {print $1; found=1} END {if (!found) print "0"}'
# So it ALWAYS prints something! Either the number or "0".
# Therefore, HOST_UPDATES is never empty! The `:-0` is redundant.
