# Routine management (first-class)

2026-09-03. Routines make "do NN every YY" a first-class riela feature: created
from chat (or CLI/GraphQL), executed on a cron schedule through the existing
event-live serve loop, tracked in SQLite, and automatically retired when a
stated completion condition is met.

## Concept

A **routine** is a durable record that ties together:

- a **task** — what to do on every tick (free-form prompt handed to the target
  workflow),
- a **schedule** — a six-field cron expression (or an `every` shorthand such as
  `30m` that riela expands deterministically),
- a **target workflow** — the workflow run on every tick (e.g. the packaged
  `routine-task-runner`),
- an optional **completion criteria** — natural-language condition; when a run
  judges it met, the routine transitions to `completed` and stops firing,
- a **status** — `active` / `disabled` (paused by hand) / `completed`, stored
  in SQLite as the source of truth.

On creation riela writes three things:

1. the routine record into the **routine store**
   (`<workingDir>/.riela/routines/routines.sqlite`, overridable with
   `RIELA_ROUTINE_STORE` or `--routine-store`),
2. a cron `EventSourceContract` JSON under `<eventRoot>/sources/`,
3. an `EventBindingContract` JSON under `<eventRoot>/bindings/` carrying the
   new `routineId` / `routineStoreRoot` fields and a template input mapping
   that injects `routineId`, `task`, and `completionCriteria` into the target
   workflow input.

The default event root is `<workingDir>/.riela/events` (same default as
`riela events serve`). Relative routine-store paths, whether explicit or from
`RIELA_ROUTINE_STORE`, are resolved against `<workingDir>` before they are
persisted into a binding, so later dispatches use one deterministic location.
List queries accept limits from 1 through 1,000 and reject values outside that
range.

## Status lifecycle and the serve-loop gate

`riela events serve` loads its config once at startup, so file edits alone
cannot stop a running loop. The SQLite status closes that gap: the cron
dispatch path (`dispatchCronTick`) looks at each trigger's binding, and when
the binding carries a `routineId` it consults the routine store **before every
run**:

- record missing → skip (orphaned binding), reason written to
  `serve-record.json`,
- status `disabled` / `completed` → skip immediately, no restart needed,
- status `active` → run, then stamp `lastRunAt` / `runCount` back into the
  record.

Completion (`riela routine complete`, the `completeRoutine` mutation, or the
`riela/routine-complete` addon) does three things:

1. sets status `completed` (+`completedAt`, optional note) in SQLite,
2. rewrites the routine's source/binding JSON with `enabled: false` so a
   restarted serve loop never even loads them,
3. when the routine was created with `deactivateWorkflowOnCompletion`,
   deactivates the target workflow through
   `WorkflowRegistryService.setActivation(.deactivated, …)` — the existing
   registry deny-list, enforced by the run-time resolver.

`disable`/`enable` flip the SQLite status and the source/binding `enabled`
fields, so a paused routine can be resumed.

## Surfaces

- **CLI** — `riela routine create|list|inspect|complete|enable|disable|delete`
  (new top-level command family; `create` accepts `--name --task
  --schedule|--every --workflow [--completion-criteria] [--timezone]
  [--instruction] [--event-root] [--routine-store]
  [--deactivate-workflow-on-completion]`).
- **GraphQL** — `routines(filter)` / `routine(routineId)` queries and
  `createRoutine` / `completeRoutine` / `setRoutineStatus` / `deleteRoutine`
  mutations, served by `RoutineGraphQLDocumentExecutor` (local-trust domain,
  same policy as configuration GraphQL) and wired into `riela graphql
  execute|document` and the RielaApp web `/graphql` fallback chain.
- **Builtin add-ons** — `riela/routine-create`, `riela/routine-complete`,
  `riela/routine-get`, `riela/routine-list`, `riela/routine-update-status`,
  `riela/routine-delete`, so workflows (in particular the chat manager) can
  manage routines as workflow nodes.

## Chat flow ("xxxをyyおきにnnする ルーチン作って")

Two packaged example workflows make the chat instruction end-to-end:

- **`examples/routine-chat-manager`** — bind it to any chat source
  (telegram/discord/slack). An agent step parses the natural-language
  instruction into a JSON command (`create` with name/task/six-field
  cron/completion criteria, or `list`/`complete`/`disable`/`enable`/`delete`),
  a routine add-on step executes it, and `riela/chat-reply-worker` confirms in
  the conversation.
- **`examples/routine-task-runner`** — the generic per-tick workflow. An agent
  step performs `task` and, when `completionCriteria` is present, judges
  whether it is now satisfied (structured output `conditionMet`); a
  `riela/routine-complete` step then completes the routine only when
  `conditionMet` is true.

## Storage

`RoutineStore` (RielaCore, on `RielaSQLite.SQLiteDatabase`) follows the house
pattern: per-operation connections, WAL writable opens, read paths that treat
a missing DB as empty, `routines` table with a JSONB `record_json` column plus
`GENERATED ALWAYS … STORED` filter columns (`name`, `status`,
`workflow_name`), explicit fractional-second timestamps, and a
`PRAGMA user_version` generation guard that hard-errors on an incompatible
older store (routine data is not regenerable).

Initial schema and index creation is transactional, so an interrupted first
write cannot leave a markerless partial schema that blocks later recovery.

`CronSchedule` moved from RielaCLI to RielaCore (public) so create-time
validation and the `every` shorthand expansion are usable from the service and
GraphQL layers; the serve loop keeps using the same type.

## Non-goals (this iteration)

- No REST `/api/v1/routines` yet (GraphQL + CLI cover the API surface; the
  app dashboard can adopt the GraphQL fields later).
- The serve loop still discovers *new* routines only on restart (config load
  is unchanged); the SQLite gate handles stop/pause/complete immediately,
  which is the safety-relevant direction.
