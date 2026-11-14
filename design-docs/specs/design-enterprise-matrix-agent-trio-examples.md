# Enterprise Matrix agent-trio examples

## Goal

Add three runnable Matrix chat examples for common enterprise work. Each room has
one manager/orchestrator and two specialists. The manager is the default public
responder, can read every team member's Note-backed persona memory, and can write
only its own memory. Each specialist can read and write only its own memory.

The three examples are:

1. security incident response: incident commander, security analyst, compliance counsel;
2. vendor onboarding: procurement lead, finance analyst, legal counsel;
3. customer escalation: support lead, product engineer, customer-success specialist.

## Runtime model

Each workflow follows the same bounded graph:

1. route a Matrix message to the manager unless a specialist is named;
2. load the selected agent's authorized memory (the manager loads all three scopes);
3. have the selected agent return a structured decision and answer;
4. optionally scaffold, register, and execute a generated workflow when `run_workflow` is true;
5. persist only the selected agent's own memory;
6. send the Matrix reply and optionally hand off to one unvisited teammate.

The generated workflow is a normal Riela workflow bundle, not a separate runtime
type. `WorkflowBundleScaffolder` creates the same `workflow.json`, file-backed node,
and external prompt layout used by `riela workflow create`. The existing mutable
registry validates and registers the bundle, and the normal workflow runner resolves
and executes it by id. A content-derived id makes identical generated tasks reusable.

The agent supplies only a short title and standalone prompt. Trusted example config
owns the backend, model, id prefix, and explicit creation opt-in. Matrix/model text
cannot supply paths, commands, credentials, node definitions, or arbitrary workflow
JSON. When no generated task is needed, `llm_only` bypasses the generation step.

## Memory authorization

`riela/note-persona-context-read` and `...-write` gain an optional trusted execution
principal:

- `actorPersonaId`: the agent executing the node;
- `allowedReadPersonaIds`: explicit scopes the actor may read;
- `teamPersonaIds`: valid handoff identities for this workflow.

At runtime, read is allowed only when the target `personaId` equals the actor or is
listed in `allowedReadPersonaIds`. Write is allowed only when target equals actor.
Omitting the new fields preserves the existing self-access behavior for old examples.
The add-on returns authorization evidence in its payload and rejects violations with
`policyBlocked` before touching Note storage.

Workflow configuration is trusted code and reviewed like any other workflow bundle.
Inbound Matrix content and model output never populate authorization fields.

## Delegation safety

Handoff identities are configured per workflow instead of being hard-coded to the
legacy Yui/Mika/Rina trio. At most one requested handoff is selected. A target already
in the trail, a self-handoff, or a handoff beyond `maxHandoffTurns` is blocked. The
reply is sanitized so a blocked continuation is not exposed as an action that will
still occur.

Generated workflow execution is bounded to a one-node workflow with one loop
iteration and the configured node timeout. The generated source staging directory is
removed after registration; the validated mutable registry copy remains reusable.

## Matrix registration

The event-source fixture declares three distinct rooms and reply identities. Each room
has one binding to its workflow and one chat destination. Tokens are referenced only
through environment-variable names. Mock runs require no credentials; local/live
Matrix verification uses the existing event-serve path.

## Verification

- unit tests prove manager read-all/write-own and specialist own-only access;
- unit tests prove arbitrary team ids retain bounded handoff behavior;
- all workflow and event contracts validate;
- deterministic mock runs cover an LLM-only path and the real generated-workflow scaffold/register/run path;
- example docs record expected session/output facts and live Matrix commands;
- package digests are refreshed after workflow and prompt edits.

Live external homeserver delivery remains credential-dependent and is not required for
the deterministic acceptance gate.
