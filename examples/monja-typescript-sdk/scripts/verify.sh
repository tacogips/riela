#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
riela_root=$(CDPATH='' cd -- "$script_dir/../../.." && pwd -P)
tmp_root="$riela_root/tmp/monja-typescript-sdk"
mkdir -p "$tmp_root"
runtime_dir=$(mktemp -d "$tmp_root/verify.XXXXXX")
mock_pid=
verification_passed=false

cleanup() {
  if [ -n "$mock_pid" ]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
  if [ "$verification_passed" = true ] && [ -d "$runtime_dir" ]; then
    node - "$tmp_root" "$runtime_dir" <<'NODE'
import fs from "node:fs";
import path from "node:path";

const root = fs.realpathSync(process.argv[2]);
const target = fs.realpathSync(process.argv[3]);
const relative = path.relative(root, target);
if (!relative.startsWith("verify.") || relative.includes(path.sep)) {
  throw new Error("refusing to remove an unexpected verification directory");
}
fs.rmSync(target, { recursive: true });
NODE
  fi
}
trap cleanup EXIT INT TERM

find_riela() {
  if [ -n "${RIELA_BIN:-}" ] && [ -x "$RIELA_BIN" ]; then
    printf '%s' "$RIELA_BIN"
    return
  fi
  for candidate in \
    "$riela_root/.build/arm64-apple-macosx/debug/riela" \
    "$riela_root/.build/x86_64-apple-macosx/debug/riela" \
    "$riela_root/.build/arm64-apple-macosx/release/riela" \
    "$riela_root/.build/x86_64-apple-macosx/release/riela"
  do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return
    fi
  done
  printf '%s\n' 'monja-verify: no built Riela executable was found' >&2
  exit 69
}

riela_bin=$(find_riela)
token=$(node -e 'process.stdout.write("monja_verify_" + crypto.randomUUID().replaceAll("-", ""))')
graphql_input='{"workflowInput":{"graphql":{"query":"query RielaSdkProbe { me { kind user { id username displayName } } }","operationName":"RielaSdkProbe"}}}'

MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" \
  MONJA_REPOSITORY_ROOT="${MONJA_REPOSITORY_ROOT:-$riela_root/../monja}" \
  "$script_dir/prepare.sh"

MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" \
  node "$script_dir/verify-url-policy.mjs" >"$runtime_dir/evidence/url-policy.json"

MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_API_KEY="$token" \
  node "$script_dir/mock-server.mjs" &
mock_pid=$!

attempt=0
while [ ! -s "$runtime_dir/mock-server.json" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    printf '%s\n' 'monja-verify: mock server did not become ready' >&2
    exit 70
  fi
  sleep 0.05
done
base_url=$(node -e 'const value=require(process.argv[1]); process.stdout.write(value.baseUrl)' "$runtime_dir/mock-server.json")

MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="$base_url" MONJA_API_KEY="$token" \
  "$riela_bin" workflow run monja-typescript-sdk \
    --variables "$graphql_input" \
    --workflow-definition-dir "$riela_root/examples" \
    --working-dir "$riela_root" \
    --session-store "$runtime_dir/sessions" \
    --artifact-root "$runtime_dir/artifacts" \
    --output json >"$runtime_dir/evidence/riela-success.json"

node - "$runtime_dir/evidence/riela-success.json" "$runtime_dir/mock-requests.json" <<'NODE'
import fs from "node:fs";

const run = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const requests = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
if (run.exitCode !== 0 || run.rootOutput?.status !== "ok") {
  throw new Error("Riela did not accept the Monja command output");
}
if (run.rootOutput?.rest?.kind !== "apiKey" || run.rootOutput?.graphql?.me?.user?.username !== "riela-sdk") {
  throw new Error("Riela output did not preserve the REST and GraphQL results");
}
const actual = requests.requests?.map(({ method, path }) => `${method} ${path}`);
const expected = [
  "GET /api/v1/auth/me",
  "GET /api/v1/server-capabilities",
  "POST /api/v1/graphql",
];
if (!requests.complete || requests.rejected || JSON.stringify(actual) !== JSON.stringify(expected)) {
  throw new Error("Monja request sequence did not match the accepted contract");
}
NODE

kill "$mock_pid"
wait "$mock_pid"
mock_pid=

valid_envelope='{"variables":{"workflowInput":{"graphql":{"query":"query RielaSdkProbe { me { kind } }","operationName":"RielaSdkProbe"}}}}'

assert_failure() {
  name=$1
  expected=$2
  if [ -s "$runtime_dir/evidence/$name.stdout" ]; then
    printf '%s\n' "monja-verify: $name wrote unexpected stdout" >&2
    exit 1
  fi
  grep -q "$expected" "$runtime_dir/evidence/$name.stderr"
}

if : | MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="https://api.example" MONJA_API_KEY="$token" \
  "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/empty.stdout" 2>"$runtime_dir/evidence/empty.stderr"; then
  printf '%s\n' 'monja-verify: empty input unexpectedly succeeded' >&2
  exit 1
fi
assert_failure empty '"stage":"input"'

if printf '%s\n' '[]' | MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="https://api.example" MONJA_API_KEY="$token" \
  "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/non-object.stdout" 2>"$runtime_dir/evidence/non-object.stderr"; then
  printf '%s\n' 'monja-verify: non-object input unexpectedly succeeded' >&2
  exit 1
fi
assert_failure non-object '"stage":"input"'

if node -e 'process.stdout.write("x".repeat(1048577))' | \
  MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="https://api.example" MONJA_API_KEY="$token" \
  "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/oversized-input.stdout" 2>"$runtime_dir/evidence/oversized-input.stderr"; then
  printf '%s\n' 'monja-verify: oversized input unexpectedly succeeded' >&2
  exit 1
fi
assert_failure oversized-input 'input_too_large'

if node -e 'process.stdout.write(JSON.stringify({variables:{workflowInput:{graphql:{query:"x".repeat(65537)}}}})+"\n")' | \
  MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="https://api.example" MONJA_API_KEY="$token" \
  "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/oversized-query.stdout" 2>"$runtime_dir/evidence/oversized-query.stderr"; then
  printf '%s\n' 'monja-verify: oversized query unexpectedly succeeded' >&2
  exit 1
fi
assert_failure oversized-query 'query_too_large'

if node -e 'process.stdout.write(JSON.stringify({variables:{workflowInput:{graphql:{query:"query RielaSdkProbe { me { kind } }",variables:{value:"x".repeat(262145)}}}}})+"\n")' | \
  MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="https://api.example" MONJA_API_KEY="$token" \
  "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/oversized-variables.stdout" 2>"$runtime_dir/evidence/oversized-variables.stderr"; then
  printf '%s\n' 'monja-verify: oversized variables unexpectedly succeeded' >&2
  exit 1
fi
assert_failure oversized-variables 'variables_too_large'
if printf '%s\n' "$valid_envelope" | env -u MONJA_BASE_URL -u MONJA_API_KEY \
  MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/missing-env.stdout" 2>"$runtime_dir/evidence/missing-env.stderr"; then
  printf '%s\n' 'monja-verify: missing configuration unexpectedly succeeded' >&2
  exit 1
fi
test ! -s "$runtime_dir/evidence/missing-env.stdout"
grep -q '"stage":"configuration"' "$runtime_dir/evidence/missing-env.stderr"

if printf '%s\n%s\n' "$valid_envelope" "$valid_envelope" | \
  MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="https://api.example" MONJA_API_KEY="$token" \
  "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/multiple.stdout" 2>"$runtime_dir/evidence/multiple.stderr"; then
  printf '%s\n' 'monja-verify: multiple JSONL records unexpectedly succeeded' >&2
  exit 1
fi
assert_failure multiple '"stage":"input"'

if printf '%s\n' "$valid_envelope" | \
  MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="http://example.com" MONJA_API_KEY="$token" \
  "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/insecure.stdout" 2>"$runtime_dir/evidence/insecure.stderr"; then
  printf '%s\n' 'monja-verify: remote plaintext URL unexpectedly succeeded' >&2
  exit 1
fi
assert_failure insecure 'insecure_host_not_allowed'

if printf '%s\n' "$valid_envelope" | \
  MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="https://api.example" MONJA_API_KEY="$token" MONJA_REQUEST_TIMEOUT_MS=0 \
  "$script_dir/run-installed-command.sh" \
  >"$runtime_dir/evidence/invalid-timeout.stdout" 2>"$runtime_dir/evidence/invalid-timeout.stderr"; then
  printf '%s\n' 'monja-verify: invalid timeout unexpectedly succeeded' >&2
  exit 1
fi
assert_failure invalid-timeout 'invalid_timeout'

run_mock_failure() {
  mode=$1
  expected=$2
  timeout_ms=${3:-15000}
  node -e 'const fs=require("node:fs"); for (const name of ["mock-server.json","mock-requests.json"]) { try { fs.unlinkSync(process.argv[1]+"/"+name); } catch (error) { if (error.code!=="ENOENT") throw error; } }' "$runtime_dir"
  MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_API_KEY="$token" MONJA_MOCK_MODE="$mode" \
    node "$script_dir/mock-server.mjs" &
  mock_pid=$!
  attempt=0
  while [ ! -s "$runtime_dir/mock-server.json" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || exit 70
    sleep 0.05
  done
  failure_base_url=$(node -e 'const value=require(process.argv[1]); process.stdout.write(value.baseUrl)' "$runtime_dir/mock-server.json")
  if printf '%s\n' "$valid_envelope" | \
    MONJA_EXAMPLE_RUNTIME_DIR="$runtime_dir" MONJA_BASE_URL="$failure_base_url" MONJA_API_KEY="$token" MONJA_REQUEST_TIMEOUT_MS="$timeout_ms" \
    "$script_dir/run-installed-command.sh" \
    >"$runtime_dir/evidence/$mode.stdout" 2>"$runtime_dir/evidence/$mode.stderr"; then
    printf '%s\n' "monja-verify: $mode unexpectedly succeeded" >&2
    exit 1
  fi
  assert_failure "$mode" "$expected"
  kill "$mock_pid"
  wait "$mock_pid"
  mock_pid=
}

run_mock_failure rest-failure '"stage":"rest"'
run_mock_failure capability-disabled '"stage":"graphql"'
run_mock_failure graphql-failure '"stage":"graphql"'
run_mock_failure timeout '"kind":"aborted"' 25
run_mock_failure oversized-rest '"stage":"rest"'
run_mock_failure oversized-graphql '"stage":"graphql"'
run_mock_failure oversized-output 'output_too_large'

if grep -R -F "$token" "$runtime_dir" --exclude='mock-server.json' >/dev/null 2>&1; then
  printf '%s\n' 'monja-verify: ephemeral API token leaked into captured evidence' >&2
  exit 1
fi

verification_passed=true
printf '%s\n' 'monja-verify: packed SDK, REST, GraphQL, JSONL, URL policy, and secret checks passed'
