API_URL="http://127.0.0.1:60378"
DURATION=180
END=$((SECONDS + DURATION))

for i in $(seq 1 20); do
  (
    while [ "$SECONDS" -lt "$END" ]; do
      curl -s "$API_URL/health" > /dev/null
    done
  ) &
done

wait