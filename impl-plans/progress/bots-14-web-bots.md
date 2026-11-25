# bots-14-web-bots progress

Step 6 implementation complete on branch **feat/bots-overview**, checkpoint
**31f978b26cae649803d0788391278fdcf49f2424**. Issue reference is the
workflow input for **fable-sol-design-and-implement-review-loop-session-1**.
Design acceptance is **comm-000004** and plan acceptance is **comm-000008**.
Dispatch accepted the required **bots-12-activity-surfaces** dependency.

## Implemented

- Added Bots navigation and encoded bot detail routes for both hosts. Changing
  profile clears the selected bot and returns to Bots.
- Rendered server-projected bot order, sections and workspace memberships,
  in-progress work, five board groups, routines and closed counts. Added
  creation, pin, snooze, settle and pause controls through GraphQL.
- Added the selected item's cursor-paged activity with retained state after
  truncation, full final-page drainage, visibility pausing, cancellation,
  and a five-second error retry. Empty active pages wait briefly before
  polling again when the server returns before its long-poll deadline.
- Rendered permission options with native IDs and Decline, refreshed after
  answering or losing a request race, and displayed handover questions with the
  owning task or session reference.

## Per-edit hashes

The pre-edit hashes of the five existing web files and the unmodified active
plan matched the native pre-node snapshot named in the dispatch. New files
were absent before creation. Exact per-edit intentions and before/after
SHA-256 values are in
**tmp/bots-overview/bots-14-web-bots/edit-intentions.md**. The source manifest
**tmp/bots-overview/bots-14-web-bots/final-web-before.sha256** matched after the
final Bun and Chromium runs. The scope check recorded every authored path.

## Verification

Bun version **1.4.4**. Log names below are relative to
**tmp/bots-overview/bots-14-web-bots/**. Exit files with the corresponding
base name record the terminal status.

| Command | Exit | Log | Result |
| --- | --- | --- | --- |
| `mkdir -p tmp/bots-overview/bots-14-web-bots` | 0 | `mkdir.log` | Evidence directory ready |
| `bun --version` | 0 | `bun-version.log` | 1.4.4 |
| `(cd web && bun install --frozen-lockfile)` | 0 | `install.log` | 189 packages installed |
| `(cd web && bun run typecheck)` | 0 | `typecheck.log` | No TypeScript diagnostics |
| `(cd web && bun test src/bots src/routes.test.ts src/App.test.ts)` | 0 | `test.log` | 32 pass, 0 fail, 90 assertions |
| `(cd web && bun run lint)` | 0 | `lint.log` | ESLint and production source audit passed |
| `(cd web && bun run build)` | 0 | `build.log` | 79 modules transformed, bundle built |
| `git status --short web/package.json web/bun.lock` | 0 | `status.log` | Empty output |
| `grep -rn "fetch(\\\|/api/v1/" web/src/bots` | 1 | `transport.log` | Empty output. The no-match assertion exited 0. |
| `bun tmp/bots-overview/bots-14-web-bots/bots-browser.ts` | 0 | `browser.log` | 1 scenario passed, 0 failed against the built console and an isolated GraphQL fixture |
| `shasum -a 256 -c tmp/bots-overview/bots-14-web-bots/final-web-before.sha256` | 0 | `identity.log` | All 20 entries matched |
| `python3 tmp/bots-overview/bots-14-web-bots/check-scope.py` | 0 | `scope.log` | Pre-node snapshot and authored write scope matched |

The initial typecheck exited 1 because two test fixtures omitted required
response fields. **typecheck.initial.log** preserves the diagnostics. The
fixtures were completed and the final typecheck exited 0.

## Completion criteria

- [x] Bots shows the server-projected ordered list, board, selected activity
  and answer controls. Focused tests and the built-console Chromium scenario
  passed, including workspace collapse and a narrow viewport.
- [x] Transport scan is empty. The client uses only shared GraphQL transport.
- [x] Package and lockfile status is empty after the frozen install.
- [x] Required gates passed and complete logs are retained.

## Deviations

The shared console executor is private. The Bots client uses the existing
console environment type, shared Riela transport and application headers.
Session-backed handovers carry a session reference in the current GraphQL
DTO. Work-task handovers display the task ID. The desktop transport cancels
browser-side handling of an obsolete long poll. A native request already
dispatched through IPC can remain active until the server's bounded wait ends.

## Open items

Formal test-integrity and adversarial review, serial integration review and
the cumulative wave gate are pending in the workflow. This step leaves the
changes unstaged.
