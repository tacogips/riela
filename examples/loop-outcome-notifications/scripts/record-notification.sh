#!/bin/sh
# Demo notification sink: the loop outcome payload arrives on stdin as one
# JSON document. Record it where the demo (or an operator) can pick it up.
cat > "${RIELA_DEMO_NOTIFY_OUT:-loop-outcome-notification.json}"
