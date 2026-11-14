#!/bin/sh
# Demonstrates the advisory loop concurrency lease end to end.
# Usage: ./examples/loop-concurrency-lease/run-demo.sh [riela-binary]
set -eu

RIELA="${1:-riela}"
STORE="${RIELA_DEMO_LEASE_STORE:-/tmp/riela-loop-lease-demo}"
WF=loop-concurrency-lease

rm -rf "$STORE"

echo "== run 1: holds the lease while the sleep step runs (~6s)"
"$RIELA" workflow run $WF \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario.json \
  --session-store "$STORE" --output json > "$STORE-run1.json" 2>&1 &
RUN1=$!

sleep 2

echo "== run 2 (concurrent): refused at preflight with loop_concurrency_busy"
set +e
"$RIELA" workflow run $WF \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario.json \
  --session-store "$STORE" --output json
RUN2_EXIT=$?
set -e
echo "run 2 exit code: $RUN2_EXIT (expected 1; no session was created)"

echo "== loop list while run 1 still holds the lease"
"$RIELA" loop list --workflow $WF --session-store "$STORE" --output json

wait $RUN1
echo "run 1 finished with status: $(python3 -c "import json;print(json.load(open('$STORE-run1.json'))['status'])")"

echo "== run 3: lease was released at terminal persistence, so this succeeds"
"$RIELA" workflow run $WF \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario.json \
  --session-store "$STORE" --output json > "$STORE-run3.json"
echo "run 3 status: $(python3 -c "import json;print(json.load(open('$STORE-run3.json'))['status'])")"
