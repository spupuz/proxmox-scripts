DISK_MSG="line 1\nline 2"

# with here-string
time for i in {1..1000}; do
  while IFS= read -r disk_line; do
    a="$disk_line"
  done <<< "$DISK_MSG"
done

# with process substitution using printf
time for i in {1..1000}; do
  while IFS= read -r disk_line; do
    a="$disk_line"
  done < <(printf "%b\n" "$DISK_MSG")
done
