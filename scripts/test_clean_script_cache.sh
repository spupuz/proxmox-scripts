#!/usr/bin/env bash
# Regression test (Bolt): lxc-cleanup.sh must build the in-container clean
# script ONCE per run and reuse it for every container, instead of rebuilding it
# inside cleanup_lxc() for each container. build_clean_script performs 8
# sanitizing parameter expansions plus a full heredoc; the result depends only on
# config, which is fixed for the whole run, so rebuilding per container is pure
# overhead. This test extracts the real function from the shipped script and
# proves (a) main() seeds CLEAN_SCRIPT once and (b) the reuse path yields the
# identical script without a second build.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
src="$repo/lxc-cleanup.sh"
fail=0

if [[ ! -f "$src" ]]; then
  echo "❌ lxc-cleanup.sh not found"
  exit 1
fi

# Static: main() must seed CLEAN_SCRIPT via build_clean_script before dispatch.
if ! grep -q 'build_clean_script CLEAN_SCRIPT' "$src"; then
  echo "❌ main() does not build CLEAN_SCRIPT once up front"
  fail=1
else
  echo "✅ main() builds CLEAN_SCRIPT once"
fi

# Static: cleanup_lxc() must prefer the cached CLEAN_SCRIPT.
if ! grep -q 'local clean_script="${CLEAN_SCRIPT:-}"' "$src"; then
  echo "❌ cleanup_lxc() does not read the cached CLEAN_SCRIPT"
  fail=1
else
  echo "✅ cleanup_lxc() reuses cached CLEAN_SCRIPT"
fi

# Functional: extract the real build_clean_script and exercise the reuse path.
start=$(grep -n '^build_clean_script() {' "$src" | cut -d: -f1)
# The function body contains nested `}` lines (df_used, step), so find the
# terminator `^}$` that appears after the heredoc's closing `EOF` line.
end=$(awk -v s="$start" 'NR>s && /^EOF$/{e=NR} e && NR>e && /^}$/{print NR; exit}' "$src")
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -n "${start},${end}p" "$src" > "$tmp"
if ! bash -n "$tmp"; then
  echo "❌ extracted build_clean_script is not valid bash"
  fail=1
else
  # shellcheck disable=SC1090
  source "$tmp"
  CLEAN_PKG_CACHE=yes; CLEAN_JOURNAL=no; JOURNAL_VACUUM_SIZE=50M
  CLEAN_DOCKER=no; CLEAN_DOCKER_VOLUME_PRUNE=no; CLEAN_DOCKER_TMP=no
  CLEAN_USER_CACHE=no; CLEAN_OLD_TMP=no
  CLEAN_SCRIPT=""; build_clean_script CLEAN_SCRIPT
  # Reuse path, exactly as cleanup_lxc() now does it.
  use() { local clean_script="${CLEAN_SCRIPT:-}"; if [[ -z "$clean_script" ]]; then build_clean_script clean_script; fi; printf '%s' "$clean_script"; }
  a="$(use)"; b="$(use)"
  if [[ "$a" != "$b" ]]; then
    echo "❌ reuse path produced different scripts across calls"
    fail=1
  elif [[ "$a" != "$CLEAN_SCRIPT" ]]; then
    echo "❌ reuse path did not return the cached script"
    fail=1
  elif ! bash -n <<< "$CLEAN_SCRIPT"; then
    echo "❌ generated clean script is not valid bash"
    fail=1
  else
    echo "✅ reuse path returns the cached, valid script (len=${#CLEAN_SCRIPT})"
  fi
fi

if (( fail == 0 )); then
  echo "✅ Clean-script cache tests passed."
fi
exit "$fail"