# Monja multi-agent collaboration example

This document specifies a reproducible Riela example in which distinct agent
personas solve one Monja task and publish their working discussion to a linked
Monja chat thread.

## Outcome

One Riela workflow runs three agent steps in order:

1. **Aster, solution architect** proposes a concrete solution and assumptions.
2. **Flint, adversarial reviewer** challenges Aster's proposal and identifies
   failure modes and required changes.
3. **Mira, decision integrator** resolves the disagreement into a final decision,
   action list, and explicit unresolved items.

Each node has its own full system prompt file. Persona identity is behavioral,
not merely a display-name substitution. All turns use structured outputs so the
runner can validate and publish them without scraping prose.

Each persona starts a separate backend conversation. Its private execution
context is not reused by another persona; accepted proposal and critique
outputs are the explicit shared memory. Aster specializes in solution framing,
Flint in failure analysis, and Mira in decision integration. These are prompt
and output-contract roles, not claims of different underlying model tools.
All agents may use the same AI-provider account. Their Monja keys determine
chat authorship, independently of their model conversations.

## Execution and discussion flow

The example runner accepts a Monja task ID and channel ID. A coordinator token
reads the task, creates a root message, and links that message to the task. It
then launches the authored workflow with task data as runtime variables.

While Riela is running, the runner polls the canonical session view. Whenever a
persona step reaches completed with accepted output, its visible `message` is
posted as a reply to the root message. The next workflow node receives prior
agent outputs through Riela's inbox, so its reasoning responds to the actual
proposal or critique. The Monja thread is a durable, human-visible projection of
the same ordered collaboration.

The existing coordinator API key can publish every persona's clearly labeled
turn. Optional separately scoped Monja bot API keys provide distinct chat
authors. The coordinator key owns task read/write, message read/write, and task
linking. Optional persona keys need only message read/write access to the configured
channel. The Riela child process receives an allowlisted execution environment
that excludes all Monja credentials.

When Mira returns `solved: true`, `unresolved` is empty, and all three marked
replies are observable in the thread, the coordinator updates the Monja task
to done. `unresolved` means blockers to the requested task; optional future
implementation choices belong in `actions`. Failure, malformed
output, missing discussion publication, or unresolved synthesis leaves the task
open and returns a nonzero status.

## Recovery and identity

Stable markers identify the collaboration root and each persona turn. Runtime
state records the task, Riela session, root message, and published reply IDs.
On restart, the runner reconciles markers from the linked Monja thread before
posting. This prevents ordinary retries from duplicating completed turns. An
ambiguous provider response may still be at-least-once; the stable marker makes
duplicates detectable.

The workflow is immutable during a run. Task descriptions and existing chat
content are data, not instructions that may override persona, output, security,
or credential constraints.

## Portable configuration

Committed fixtures contain only fake IDs and environment variable names. Live
resource IDs belong in an ignored file under repository-root `tmp/`. The API URL
must use HTTPS, except loopback HTTP for deterministic tests. State and generated
payloads stay under the repository `tmp/` tree.

```typescript
type PersonaId = "architect" | "skeptic" | "integrator";

interface CollaborationConfig {
  readonly taskId: string;
  readonly channelId: string;
  readonly completeTaskOnSuccess: boolean;
}

interface DiscussionTurn {
  readonly persona: PersonaId;
  readonly displayName: string;
  readonly message: string;
  readonly solved?: boolean;
}

interface CollaborationState {
  readonly taskId: string;
  readonly rootMessageId: string;
  readonly sessionId: string | null;
  readonly published: Readonly<Partial<Record<PersonaId, string>>>;
}
```

## Verification

Deterministic verification must validate and inspect the authored bundle, then
run the real Riela CLI with a mock scenario against a fake Monja API. Assertions
cover persona order, distinct system prompts, accepted-output schema, prior-turn
context, distinct bearer tokens, one linked root thread, idempotent retry, final
task completion, and credential exclusion from the Riela subprocess.

A live acceptance run must use a real Monja task, channel, three clearly labeled
personas, and real Riela agent executions. A shared existing API key is sufficient;
distinct bot authors are optional. It must record only non-secret task,
message, author, session, and final-status evidence.

## References

See `design-docs/references/README.md` for external references. The workflow
authoring and test contracts follow the installed Riela workflow skills.
