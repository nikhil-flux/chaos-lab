#!/usr/bin/env bash
# Resilience gate used by CI (and runnable locally).
# Kills an inventory pod while traffic is flowing, then requires:
#   - at least MIN_SUCCESS percent of requests succeeded, and
#   - every pod in the app is Ready again afterwards.
set -euo pipefail

NS="${NS:-shop}"
PORT="${PORT:-18080}"
DURATION="${DURATION:-60}"
MIN_SUCCESS="${MIN_SUCCESS:-85}"
URL="http://localhost:${PORT}"

cd "$(dirname "$0")/.."

echo "Waiting for deployments..."
kubectl -n "$NS" wait --for=condition=Available deploy --all --timeout=180s

kubectl -n "$NS" port-forward svc/frontend "${PORT}:8080" >/dev/null 2>&1 &
PF=$!
cleanup() {
  kill "$PF" 2>/dev/null || true
  kubectl delete -f chaos/pod-kill.yaml --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 30); do
  curl -sf "${URL}/healthz" >/dev/null && break
  sleep 1
done

curl -sf "${URL}/checkout" >/dev/null || { echo "FAIL: baseline checkout failed"; exit 1; }
echo "Baseline OK. Injecting pod-kill for ${DURATION}s of traffic..."

kubectl apply -f chaos/pod-kill.yaml

total=0
ok=0
END=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$END" ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${URL}/checkout" || true)"
  total=$((total + 1))
  if [ "$code" = "200" ]; then
    ok=$((ok + 1))
  fi
  sleep 0.2
done

pct=$((100 * ok / total))
echo "Success rate under chaos: ${ok}/${total} (${pct}%), required >= ${MIN_SUCCESS}%"

echo "Waiting for full recovery..."
kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/part-of=chaos-lab --timeout=120s

if [ "$pct" -lt "$MIN_SUCCESS" ]; then
  echo "FAIL: success rate below threshold"
  exit 1
fi
echo "PASS: service stayed available and recovered."
