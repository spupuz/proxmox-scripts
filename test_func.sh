check1() {
    VAL=$(echo "123")
    echo "${VAL:-0}"
}

check2() {
    echo "123"
}

time for i in {1..1000}; do
    res=$(check1 || echo "error")
done

time for i in {1..1000}; do
    res=$(check2 || echo "error")
done
