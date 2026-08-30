#!/bin/bash
# Test the sanitization regex logic used in the script
test_sanitize() {
  local app_cmd="$1"
  local safe_app_cmd="${app_cmd//[^a-zA-Z0-9_\-\.\/ ]/}"
  if [[ "$app_cmd" != "$safe_app_cmd" ]]; then
    echo "REJECTED: $app_cmd"
  else
    echo "ACCEPTED: $app_cmd"
  fi
}

fail=0
out1=$(test_sanitize "/usr/local/bin/update")
if [[ "$out1" != "ACCEPTED: /usr/local/bin/update" ]]; then
  echo "❌ Test 1 failed! Got $out1"
  fail=1
fi

out2=$(test_sanitize "update")
if [[ "$out2" != "ACCEPTED: update" ]]; then
  echo "❌ Test 2 failed! Got $out2"
  fail=1
fi

out3=$(test_sanitize "/bin/update; rm -rf /")
if [[ "$out3" != "REJECTED: /bin/update; rm -rf /" ]]; then
  echo "❌ Test 3 failed! Got $out3"
  fail=1
fi

out4=$(test_sanitize "update & echo pwned")
if [[ "$out4" != "REJECTED: update & echo pwned" ]]; then
  echo "❌ Test 4 failed! Got $out4"
  fail=1
fi

out5=$(test_sanitize "/bin/update\`whoami\`")
if [[ "$out5" != "REJECTED: /bin/update\`whoami\`" ]]; then
  echo "❌ Test 5 failed! Got $out5"
  fail=1
fi

out6=$(test_sanitize "pihole -up")
if [[ "$out6" != "ACCEPTED: pihole -up" ]]; then
  echo "❌ Test 6 failed! Got $out6"
  fail=1
fi

out7=$(test_sanitize "ha core update")
if [[ "$out7" != "ACCEPTED: ha core update" ]]; then
  echo "❌ Test 7 failed! Got $out7"
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "✅ App cmd sanitization tests passed."
fi
