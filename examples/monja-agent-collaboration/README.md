# Monja agent collaboration

One Riela workflow discusses one Monja task and publishes an ordered, task-linked
thread. The default participants are Aster (constructive architect), Flint
(adversarial reviewer), and Mira (final integrator). `participants.json` maps
each workflow step to its display name, bot credential environment name, and
final-decision responsibility.

Each role starts a fresh private backend session and uses a read-only sandbox.
The next role receives the preceding native accepted payload, including a flat
`priorTurns` transcript. Each transcript item preserves the original
`persona`, `message`, and `details`; it excludes nested transcript history.
The runner checks that every item exactly equals the corresponding accepted
turn. Native node `output.jsonSchema` supplies output guidance and validation;
prompts describe role behavior rather than duplicating JSON shapes.

## Setup and run

From the source checkout, build the CLI and install the locked example tooling:

```sh
swift build --product riela
cd examples/monja-agent-collaboration
bun install --ignore-scripts --frozen-lockfile
cd ../..
```

An installed `riela` binary also works. All roles can use the same AI-provider
account and `OPENAI_API_KEY` or authenticated Codex environment. Separate Monja
bot keys identify chat authors; they are unrelated to provider credentials.
For shared provider-key mode, include `OPENAI_API_KEY` in Kinko's `--env`
allowlist in the commands below. Alternatively, use the existing authenticated
Codex environment. No per-participant AI-provider key is required.
Every configured participant token is required, and participant authors must be
distinct. There is no coordinator fallback.

| Variable | Purpose |
| --- | --- |
| `MONJA_API_URL` | Full HTTPS API base ending in `/api/v1`; loopback HTTP allowed |
| `MONJA_API_TOKEN` | Coordinator task/link/root/read credential |
| `MONJA_ARCHITECT_TOKEN` | Aster bot credential |
| `MONJA_SKEPTIC_TOKEN` | Flint bot credential |
| `MONJA_INTEGRATOR_TOKEN` | Mira bot credential |
| `RIELA_BIN` | Executable, default `riela` |
| `RIELA_WORKFLOW_ROOT` | Directory containing the `monja-agent-collaboration` bundle |
| `MONJA_COLLABORATION_STATE` | State directory under repository `tmp/` |
| `MONJA_COLLABORATION_COMPLETE_TASK` | `false` leaves a solved task open |
| `MONJA_COLLABORATION_RETRY_FAILED` | `true` permits one preserved-history recovery per invocation |
| `MONJA_COLLABORATION_POLL_MS` | Positive polling interval, default 1000 |
| `MONJA_COLLABORATION_TIMEOUT_MS` | Positive wait deadline, default 1800000 |

Inject secrets using Kinko:

```sh
RIELA_BIN=.build/debug/riela \
  kinko exec --env MONJA_API_URL,MONJA_API_TOKEN,MONJA_ARCHITECT_TOKEN,MONJA_SKEPTIC_TOKEN,MONJA_INTEGRATOR_TOKEN -- \
  bun examples/monja-agent-collaboration/main.ts <task-id> <channel-id>
```

The coordinator needs task read/write, link, and channel read/write access.
Participant bots need channel message creation. Configuration, sequential graph,
fresh-session policy, native output schemas, and authenticated identities are
checked before discussion writes. Model children and the CLI verifier use the
same small environment allowlist; no `MONJA_*` credential enters those children.

Completion requires every configured accepted turn, a final `solved: true`,
empty `unresolved`, nonempty `acceptanceCriteria`, and exact canonical thread
identity/content/author/parent checks. The default final schema requires five
testable criteria. A solved discussion means a decision ready for the task
owner; it does not claim external implementation work.

## Add a participant

1. Insert an entry in `participants.json` with a unique step ID, display name,
   dedicated `MONJA_*_TOKEN`, and `finalDecision: false`.
2. Add the node registry entry, fresh worker step, and sequential transitions
   at the same position in `workflow.json`.
3. Add a node and independent role prompts. Keep the generic
   `persona/message/details/priorTurns` envelope; place role-specific fields
   inside `details` and define their native schema.
4. Preserve preceding flat transcript items and append the immediately
   preceding turn's `persona/message/details`. Keep exactly one final decision
   participant, last in the ordered configuration.
5. Provision its distinct Monja bot key and validate the workflow.

No runner TypeScript changes are required. The executable four-role test adds
Rowan, an operator reviewer, using only bundle/configuration/prompt changes and
a labeled deterministic model fixture. Use a new state directory for a changed
participant configuration.

## Restart and recovery

State defaults to `tmp/monja-agent-collaboration/<task-id>/state.json`.
A process-owned SQLite writer lock prevents competing runners and releases
automatically after process exit or crash. Keep the state directory: version 2
binds task/channel, ordered participant identities, authenticated authors, the
original task snapshot, immutable message requests, and session lineage.
Expected task status changes and later title edits do not rewrite the original
workflow input or root publication request.

Each root/reply uses Monja's native author/channel-scoped `idempotencyKey`.
The exact original content/key/parent request is saved before sending.
An uncertain response retries the same request; server replay returns the
canonical original. The runner rejects edited, deleted, misattributed, or
duplicated observed messages rather than completing from saved IDs alone.
This requires the Monja message-creation identity migration/API implementation.

Re-run the same command after an interruption. Before spawning Riela, the
runner persists an initial/recovery intent with a unique log identity. A
restart recovers the session from the existing JSONL log and checks its
canonical persisted identity. It never launches again merely because saving
the session ID was interrupted.

If no session identity is observable, the runner reports an **indeterminate
launch** with the exact log filenames and leaves state intact. Inspect those
logs and the retained session store, and wait for any original child to exit
before retrying reconciliation. Do not delete state or launch claims to bypass
the check: the child may already have made model calls. A crash before any
identity was recorded requires operator reconciliation.

A failed final step stays failed unless explicitly retried:

```sh
MONJA_COLLABORATION_RETRY_FAILED=true RIELA_BIN=.build/debug/riela \
  kinko exec --env MONJA_API_URL,MONJA_API_TOKEN,MONJA_ARCHITECT_TOKEN,MONJA_SKEPTIC_TOKEN,MONJA_INTEGRATOR_TOKEN -- \
  bun examples/monja-agent-collaboration/main.ts <task-id> <channel-id>
```

The runner calls `session rerun <source> <failed-step> --preserve-history`.
Riela imports accepted prefix evidence and starts only the failed target in a
new inspectable session. The root and earlier replies remain unchanged.
Compatible failed-target prompt/output-schema repair is allowed; the runner
does not hash all prompt bytes. Native recovery rejects incompatible history.
Each invocation permits at most one recovery attempt, including reconciliation
of an interrupted recovery launch. A second terminal failure requires another
explicit invocation after diagnosis.

## Verification

```sh
bun examples/monja-agent-collaboration/verify-workflow.ts
(
  cd examples/monja-agent-collaboration
  bun run lint
  bun run typecheck
  bun test --coverage
)
```

The actual CLI runs use labeled `scenario-mock` model responses. Tests cover
default/four participants, preserved recovery after target repair, immutable
publication replay after uncertain responses, interrupted session-ID saves,
launch reconciliation, canonical tampering, configuration rejection, credential
isolation, and writer-lock process crashes. The local fake API exercises the
client contract; it is not evidence of production deployment or D1 durability.
Run the combined real D1/API, Bun example process, and Swift CLI acceptance
from the sibling Monja checkout. Starting again at the Riela repository root
(both repositories and their existing locked tooling must be available):

```sh
cd ../monja
bun test tests/collaboration-acceptance/acceptance.test.ts
bunx --no-install tsc -p tests/collaboration-acceptance/tsconfig.json
```

This suite creates isolated Miniflare D1 databases with the actual schema and
API composition, creates bot identities through REST, and stubs only realtime
delivery. It covers default/four participants, preserved final-step repair,
successful responses discarded after committed root/reply writes, runner
process restarts, the session-ID save crash window, and concurrent native
message creation under an exact storage cap. It writes credential-free
`acceptance.json` evidence under Riela `tmp/collaboration-d1-*/`.
The API/database stay alive while the runner process restarts. The injected
HTTP fault is a 503 replacing a committed successful response, not a TCP-loss
or database-process-crash test. No real model calls or deployment are involved.
See the [combined acceptance report](../../../monja/design-docs/specs/design-agent-collaboration-extensibility-acceptance.md).
See [EXPECTED_RESULTS.md](./EXPECTED_RESULTS.md).

The [earlier live acceptance report](../../design-docs/specs/design-monja-agent-collaboration-live-acceptance.md)
describes the previous fixed three-role contract, not acceptance of this revision.
