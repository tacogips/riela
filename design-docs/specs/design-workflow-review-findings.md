# Workflow Review Findings Persistence

## Issue Source

- Issue reference: `tacogips/cursor-agent#123`
- Workflow mode: `issue-resolution`
- Step 1 intake source of truth: review findings are lost across workflow reruns,
  so retries cannot reliably address earlier high or mid feedback.
- Acceptance signals:
  - review findings remain available after a rerun;
  - implementation retries can read prior high and mid feedback.

No Codex-reference input was provided by Step 1. The local `../../codex-agent`
reference repository is therefore not a behavior source for this issue.

## Behavior

Riela must persist review findings that are produced by review steps and replay
the relevant unresolved findings into later rerun or retry context.

The persisted record is workflow-runtime metadata, not an adapter-local artifact.
It must be available to any backend that participates in the workflow, including
`codex-agent`, `claude-code-agent`, `cursor-cli-agent`, and future adapters.

The first supported replay target is high and mid findings from review steps that
route execution back to an authoring or implementation step. Low findings can be
persisted for audit visibility, but they must not force rerun routing unless the
workflow transition rules already do so.

## Boundaries

The workflow runtime owns:

- collecting review findings from structured worker output;
- validating finding severity and required fields;
- storing review-finding records with workflow execution metadata;
- selecting prior findings for a rerun or retry prompt context;
- exposing persisted findings through session inspection/export surfaces.

Agent adapters own only delivery of the runtime-provided context to their worker
prompt. Cursor-specific command behavior must stay isolated behind the
`cursor-cli-agent` adapter. The adapter must not define independent retention,
storage, or severity semantics.

Design documentation stays in `design-docs/`; implementation plans and progress
logs remain outside this document.

## Data Flow

1. A review step completes and returns structured output with `findings`,
   `feedback`, `accepted`, and a review decision such as `needs_revision`.
2. The workflow runtime normalizes each finding into a persisted review-finding
   record.
3. The record is stored with the workflow session or execution metadata before
   transition routing continues.
4. When a rerun, retry, or return transition starts an affected authoring step,
   the runtime selects unresolved high and mid findings from prior review
   records for that workflow execution.
5. The selected findings are injected into the worker input as prior review
   feedback, preserving file path, line, severity, message, source review step,
   and originating issue reference.
6. Session inspection and export include the stored review findings so operators
   can audit which feedback was available to a retry.

## Record Shape

Each persisted review finding should carry:

- stable finding id derived from session id, review step id, review attempt, and
  finding index;
- issue reference and workflow mode;
- source review step id and source execution attempt;
- target step id when supplied by the review output;
- file path and line when supplied;
- severity: `high`, `mid`, or `low`;
- message and actionable feedback text;
- status: `open`, `addressed`, or `superseded`;
- creation timestamp and the session/execution id that produced it.

The runtime may derive `addressed` or `superseded` status from a later accepted
review or from explicit implementation metadata. Until that exists, findings
should remain `open` and still be replayed when severity and target rules match.

## Validation Rules

- Findings with unknown severity are rejected or downgraded only through an
  explicit validation diagnostic; silent coercion is not allowed.
- Missing `file` or `line` is allowed for cross-cutting findings, but `message`,
  `severity`, and source review step id are required.
- Only high and mid findings cause mandatory return-to-author routing.
- Replayed context must preserve the original review wording and source metadata
  without fabricating file paths or line numbers.
- Persisted records must not contain adapter secrets, environment variables, or
  raw command logs.

## Cursor CLI Behavior Mapping

The persisted-finding behavior is backend-neutral. For `cursor-cli-agent`:

- command construction, model checks, stream handling, and output normalization
  remain adapter responsibilities;
- persisted review findings enter the adapter only as runtime-provided prompt
  context;
- the adapter must not maintain a separate review-finding ledger;
- Cursor-specific differences must be limited to prompt/context formatting needed
  by the adapter transport.

## Retention Decision

The unresolved retention duration is tracked in
`design-docs/user-qa/qa-review-finding-retention.md`.

Until the user decides retention duration, implementation should retain findings
for at least the lifetime of the workflow session and avoid any permanent purge
behavior that would make rerun feedback unavailable.

## Rollout Constraints

- Add storage and replay behavior behind the existing workflow session metadata
  boundary before exposing new command output.
- Preserve existing step-addressed workflow behavior and transition routing.
- Existing sessions without review-finding records must continue to load.
- Migration or compatibility logic must treat missing review-finding records as
  an empty set.
- Regression verification must prove a review finding produced before rerun is
  available to the retry step.

## Issue To Design Mapping

- Lost findings across reruns map to persisted review-finding records.
- Retry workers lacking feedback map to runtime replay into rerun context.
- Auditability maps to session inspection/export inclusion.
- Unknown retention semantics map to the user QA record rather than an embedded
  product decision.

## Risks

- Retention duration is not yet decided.
- If later implementation infers addressed status too aggressively, unresolved
  high or mid findings could stop replaying too early.
- Adapter-specific formatting could accidentally hide runtime-provided findings
  from `cursor-cli-agent` if not covered by tests.
