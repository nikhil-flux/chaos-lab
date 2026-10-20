#!/usr/bin/env bash
# Generate steady traffic against the frontend so the dashboard has data.
# Usage: scripts/load.sh [duration_seconds=300] [workers=5]
# Each worker sends about one request per second.
set -euo pipefail

DURATION="${1:-300}"
WORKERS="${2:-5}"
NS="${NS:-shop}"
PORT="${PORT:-18080}"
URL="http://localhost:${PORT}/checkout"

kubectl -n "$NS" port-forward svc/frontend "${PORT}:8080" >/dev/null 2>&1 &
PF=$!
RESULTS="$(mktemp)"
trap 'kill "$PF" 2>/dev/null || true; rm -f "$RESULTS"' EXIT

for _ in $(seq 1 30); do
  curl -sf "http://localhost:${PORT}/healthz" >/dev/null && break
  sleep 1
done

echo "Sending ~${WORKERS} req/s to ${URL} for ${DURATION}s (Ctrl-C to stop)..."
END=$((SECONDS + DURATION))

worker() {
  while [ "$SECONDS" -lt "$END" ]; do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 "$URL" >>"$RESULTS" || echo 000 >>"$RESULTS"
    sleep 1
  done
}

for _ in $(seq 1 "$WORKERS"); do
  worker &
done
wait

echo "Status code summary:"
sort "$RESULTS" | uniq -c
