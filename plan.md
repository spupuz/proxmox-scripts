1. **Optimize package list formatting in `system-update-notifier.sh`:**
   - Locate the string formatting pipeline (`clean_list=$(printf ... | tr ... | grep ... | sed ...)`) around line 325.
   - Replace it with pure Bash native formatting using `printf -v` and parameter expansion (e.g. `clean_list="${clean_list//_/\\_}"`).
   - Use `set -f` to temporarily disable globbing before expanding the unquoted `$UPGRADE_LIST` to prevent pathname expansion, and verify the string isn't empty/whitespace-only (`[[ -n "${UPGRADE_LIST//[[:space:]]/}" ]]`).
   - Ensure the new logic appends `clean_list` to `REPORT` matching the original newline behavior.
2. **Verify changes:**
   - Execute the script or test scripts locally to confirm that it works as expected without errors.
3. **Complete pre-commit steps:**
   - Complete pre-commit steps to ensure proper testing, verification, review, and reflection are done.
4. **Submit PR:**
   - Create a PR prefixed with `⚡ Bolt:` documenting the impact and measurement.
