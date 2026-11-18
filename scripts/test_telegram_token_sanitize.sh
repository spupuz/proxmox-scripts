#!/bin/bash
# Test that Telegram TOKEN sanitization prevents injection through the
# URL that is passed to curl via a -K config file. Mirrors the safe_token
# sanitization applied in send_telegram() of all four main scripts.
sanitize() {
  local tok="$1"
  local safe="${tok//\"/}"
  safe="${safe//$'\n'/}"
  safe="${safe//$'\r'/}"
  printf '%s' "$safe"
}

fail=0

# 1. Normal token passes through unchanged
out=$(sanitize "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11")
[[ "$out" == "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11" ]] || { echo "❌ Test 1 failed: got '$out'"; fail=1; }

# 2. Double quote is stripped (prevents curl -K directive injection)
out=$(sanitize '123"456')
[[ "$out" == "123456" ]] || { echo "❌ Test 2 failed: got '$out'"; fail=1; }

# 3. Newline is stripped (prevents config-line injection)
out=$(sanitize $'123\n456')
[[ "$out" == "123456" ]] || { echo "❌ Test 3 failed: got '$out'"; fail=1; }

# 4. Carriage return is stripped
out=$(sanitize $'123\r456')
[[ "$out" == "123456" ]] || { echo "❌ Test 4 failed: got '$out'"; fail=1; }

# 5. Combined injection attempt cannot inject a curl directive
out=$(sanitize '123" --proto "http"')
[[ "$out" == "123 --proto http" ]] || { echo "❌ Test 5 failed: got '$out'"; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo "✅ Telegram token sanitization tests passed."
fi
exit $fail