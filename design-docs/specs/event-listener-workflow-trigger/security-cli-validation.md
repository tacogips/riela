# Event Listener Workflow Trigger Design: Security, CLI, Validation, and Milestones

## Security Model

Rules:

- provider credentials are referenced by environment variable names or runtime
  secrets, never stored in workflow JSON or binding output artifacts
- webhook signatures must be verified before normalization
- webhook replay windows should be enforced when the provider supplies signed
  timestamps
- event HTTP endpoints must be disabled unless explicitly configured
- raw provider payloads should be artifacted with filesystem permissions
  consistent with other riela runtime artifacts
- input mapping should copy only intentional fields into `workflowInput`
- attachments must be stored under the riela data root and passed as
  data-root-relative refs
- event APIs should support rate limits per source id
- S3 repository sources must enforce bucket and prefix allow lists before
  dispatching workflow execution
- S3 repository sources must reject polling mode; accepted events must come
  through a configured event receiver
- S3 object content download must require explicit configuration and least
  privilege read access
- S3 object keys must never be used directly as local filesystem paths

## CLI And Server Surface

Recommended CLI additions:

- `events validate [--event-root <path>]`
- `events serve [--event-root <path>] [--endpoint <graphql-url>]`
- `events emit <source-id> --event-file <path>`
- `events list [--source <id>] [--status <status>]`
- `events replay <receipt-id>`

`events serve` should be able to run in two modes:

- local mode: invokes `createWorkflowExecutionClient()` without endpoint and
  executes workflows in-process
- remote mode: uses GraphQL `executeWorkflow` against `--endpoint`

When a binding uses `execution.mode = "supervised"`, both local and remote modes
must route through the supervisor control contract rather than direct target
execution. The same event source should then be able to start a target workflow
and later stop, restart, or inspect it by correlation key.

Recommended environment variables:

- `RIELA_EVENT_ROOT`
- `RIELA_EVENT_ENDPOINT_BASE_URL`
- `RIELA_EVENTS_ENABLED`
- `RIELA_EVENTS_READ_ONLY`

`riela serve` may later gain `--events`, but the first implementation should
prefer a separate command to keep the control plane and event listener lifecycle
clear.

## Validation Rules

Event config validation should fail when:

- a binding references an unknown source id
- a binding references an unknown workflow name
- a source kind has no registered adapter
- a provider secret env var name is malformed
- a file-change source omits `directory`, uses a non-string directory, or
  resolves to a path that does not exist, is not a directory, or is not readable
  when `events validate` runs in local mode
- a file-change source uses empty, unknown, non-string, or duplicate
  `changeTypes`; allowed values are only `create`, `modify`, and `delete`
- a file-change source configures malformed `filters.suffixes`, including
  empty suffixes, non-string suffixes, suffixes containing path separators, or
  duplicate suffixes
- a file-change source sets `recursive` to a non-boolean value, or enables
  recursive watching on a runtime/platform path where recursive watch support
  cannot be provided deterministically
- a file-change source sets `stabilityWindowMs` below zero or above the
  adapter's documented upper bound
- a sequential-list source omits `entries`, configures an empty entries array,
  or uses non-object entries
- a sequential-list entry omits `id`, uses an empty or duplicate `id`, or uses
  an id that is not safe for receipt/state display
- a sequential-list entry omits `prompt` or uses an empty/non-string prompt
- a sequential-list entry sets non-object `metadata`
- a sequential-list source sets unknown `startPolicy` or `onItemFailure`
  values
- a cron schedule cannot be parsed
- an S3 repository source omits bucket, event receiver configuration, or an
  explicit object access policy
- an S3 repository source configures polling as its receiver mode
- an S3 repository source configures a root prefix or suffix filter that cannot
  be represented as a safe repository path rule
- a Matrix source omits `homeserverUrlEnv`, `accessTokenEnv`, `userId`, or at
  least one room id
- a Matrix source uses malformed environment variable names for homeserver URL
  or access token configuration
- a Matrix source room id does not look like a Matrix room id beginning with
  `!`, or `userId` does not look like a Matrix user id beginning with `@`
- Matrix sync timing fields such as `pollTimeoutMs` are non-positive or exceed
  the adapter's supported long-poll bounds
- Matrix `sync.sinceTokenPath` is absolute, empty, or contains path traversal
- Matrix `attachments` is non-object, uses a non-boolean `downloadText`, sets a
  non-positive or oversized `maxBytes`, or provides an empty/non-string
  `allowedMimeTypes` entry
- `match.eventType` is unsupported by the source adapter capability metadata
- `inputMapping` references paths not present in the normalized event schema
  when the schema is statically known
- `execution.maxConcurrentPerKey` is less than 1
- `execution.mode` is neither `"direct"` nor `"supervised"`
- `execution.mode = "supervised"` has no finite restart limit after defaults
  are applied
- `execution.mode = "supervised"` allows multiple active runs for the same
  correlation key without requiring an explicit target alias or supervised run id
- `execution.async: false` is used for webhook-backed sources unless explicitly
  allowed by an unsafe/local option

## Implementation Milestones

1. Event config loader and validator.
2. Event ledger artifacts plus SQLite index.
3. Generic `EventSourceAdapter` registry and manual `events emit`.
4. Cron adapter.
5. S3 repository file-created adapter with metadata-only input.
6. Local file-change adapter with `file-change` source registration,
   validation, create/modify/delete dispatch gating, deterministic watcher
   tests, example source/binding fixtures, and user-facing configuration and
   run documentation.
7. Sequential-list adapter with source registration, validation, durable
   sequence state, terminal-completion observation, no-concurrent-dispatch
   tests, event receipt/list/replay coverage, example source/binding fixtures,
   and user-facing configuration and run documentation.
8. Generic webhook adapter for local testing.
9. Matrix adapter for Element/Matrix room receive normalization and chat reply
   dispatch.
10. Chat SDK adapter family for Slack, Teams, Google Chat, Discord, Telegram,
   GitHub, Linear, WhatsApp, Messenger, and Web.
11. Optional dedicated web chat UI adapter when browser UX needs behavior beyond
   the shared Chat SDK `web` provider boundary.
12. Optional S3 object download-to-data-root support.
13. Optional reply publisher after workflow completion.
14. Signal adapter if operational requirements and dependency choice are
    accepted.
15. Supervised event control path for chat and web app lifecycle commands.

## References

See `design-docs/references/README.md` for external reference links.
