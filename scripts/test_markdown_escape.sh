#!/bin/bash
set -e

# Test 1: Function simulating the escape logic
escape_markdown() {
  local str="$1"
  str="${str//_/\\_}"
  str="${str//\*/\\*}"
  str="${str//\[/\\[}"
  str="${str//\]/\\]}"
  str="${str//\`/\\\`}"
  echo "$str"
}

# Test input
input_str='host_name*1[a]`'
expected_output='host\_name\*1\[a\]\`'
actual_output=$(escape_markdown "$input_str")

if [[ "$actual_output" == "$expected_output" ]]; then
  echo "✅ Markdown escape test passed."
else
  echo "❌ Markdown escape test failed!"
  echo "Expected: $expected_output"
  echo "Actual:   $actual_output"
  exit 1
fi
