#!/bin/sh
# Test-only vendor stand-in. Never copied into a production worker image.
set -eu
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'codex-cli 1.0.0-fixture'
  exit 0
fi
if [ -n "${RIELA_TEST_CLI_RECEIPT:-}" ]; then
  printf '%s\n' "$*" >> "$RIELA_TEST_CLI_RECEIPT"
fi
cat >/dev/null
printf '%s\n' \
  '{"type":"thread.started","thread_id":"fixture-vendor-thread"}' \
  '{"type":"item.completed","item":{"type":"agent_message","text":"generated container fixture"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
