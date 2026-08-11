#!/bin/bash
set -u

if [ "$PWD" = "/" ]; then
  echo "Error: no working directory"
  exit 1
fi

mkdir -p /logs/verifier
cd /app || exit 1

rm -f /app/releases.duckdb
rm -f /app/distribution-gateway/data/gateway.json

gateway_pid=""
cleanup() {
  if [ -n "$gateway_pid" ]; then
    kill "$gateway_pid" 2>/dev/null || true
    wait "$gateway_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! curl -fsS http://127.0.0.1:7070/healthz >/dev/null 2>&1; then
  (cd /app/distribution-gateway && node server.js >/tmp/gateway.log 2>&1) &
  gateway_pid=$!
  for _ in $(seq 1 50); do
    if curl -fsS http://127.0.0.1:7070/healthz >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
fi

if ! curl -fsS http://127.0.0.1:7070/healthz >/dev/null 2>&1; then
  echo 0 > /logs/verifier/reward.txt
  exit 1
fi

if [ -x /app/solution/publish.sh ]; then
  /app/solution/publish.sh >/tmp/solution-install.log
else
  echo "missing solution/publish.sh"
  echo 0 > /logs/verifier/reward.txt
  exit 1
fi

if ! npm run report >/tmp/publisher-first.out; then
  echo 0 > /logs/verifier/reward.txt
  exit 1
fi

if ! npm run report >/tmp/publisher-second.out; then
  echo 0 > /logs/verifier/reward.txt
  exit 1
fi

PUBLISHER_OUTPUT=/tmp/publisher-first.out \
PUBLISHER_OUTPUT_SECOND=/tmp/publisher-second.out \
python -m pytest --ctrf /logs/verifier/ctrf.json /app/tests/test_outputs.py -rA
code=$?

echo "pytest exit code: ${code}"
if [ "$code" -eq 0 ]; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
exit "$code"
