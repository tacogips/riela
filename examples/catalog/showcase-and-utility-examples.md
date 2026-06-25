# Examples: Showcase and Utility Examples

### `node-combinations-showcase`

Validation-oriented reference bundle in the step-addressed authored shape:

- `managerStepId` / `entryStepId` plus explicit `steps[]` transitions (the
  foreach lane uses two labeled transitions from the judge step:
  `continue_items` back to `foreach-manager` and `!(continue_items)` forward to
  `foreach-output`, matching the former repeat-edge semantics)
- one task uses `nodeType: "command"`
- one task uses `nodeType: "container"`
- workflow-relative support assets are included for the command script and
  container build context
- node payload files live under `nodes/`

Execution notes:

- live `workflow run` can execute the authored `command` and `container` nodes
  when the local runtime prerequisites are available
- inspect or validate the workflow first to confirm runner readiness in the
  current environment before relying on a live run
- the bundled deterministic mock scenario remains the stable demo path when you
  want reproducible results without depending on local shell or container
  tooling

Validate it:

```bash
riela workflow validate node-combinations-showcase --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect node-combinations-showcase --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run node-combinations-showcase \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/node-combinations-showcase/mock-scenario.json \
  --output json
```

### `scheduled-sleep`

Minimal scheduled continuation workflow:

- `wait` uses `nodeType: "sleep"` with `sleep.durationMs`
- the runtime records a pending `workflow-sleep` scheduled event and returns
  while the workflow session is paused
- when the shared scheduled event manager fires the event, the session resumes
  and runs `worker`
- cancellation only applies to pending scheduled events, so firing, fired,
  failed, and already-cancelled event states remain visible for inspection

Run it with the bundled deterministic scenario:

```bash
riela workflow run scheduled-sleep \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/scheduled-sleep/mock-scenario.json \
  --output json
```

### `first-four-arithmetic-pipeline`

Validation-oriented arithmetic pipeline reference:

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` carries the add, multiply, and divide stages directly
- accepts a human input string containing at least four space-separated numbers
- uses only the first four numbers from that input
- stage 1 uses an `agent` worker to add the first two numbers
- stage 2 uses a `container` worker configured for `podman` to multiply the
  stage 1 result by the third number
- stage 3 uses a `command` worker to divide the stage 2 result by the fourth
  number
- managers treat each stage as an opaque grouped lane and only move scoped
  payloads forward
- stage payloads live under `workflows/add`, `workflows/multiply`, and
  `workflows/divide`
- those nested stage payloads reuse the parent-level `prompts/stage-manager.md`,
  which demonstrates workflow-local asset
  reuse across nested directories

Execution notes:

- live `workflow run` can execute the authored `command` and `container`
  workers when the required local shell and container runner tooling is
  available
- inspect or validate the workflow first to confirm runner readiness in the
  current environment before relying on a live run
- the bundled deterministic mock scenario remains the stable verification path
  when you want reproducible arithmetic results without depending on local
  toolchain availability

Validate it:

```bash
riela workflow validate first-four-arithmetic-pipeline --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect first-four-arithmetic-pipeline --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run first-four-arithmetic-pipeline \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/first-four-arithmetic-pipeline/mock-scenario.json \
  --output json
```

### `claude-riela-claude-worker`

Reference workflow for the case where a regular task node also uses
`claude-code-agent`:

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` expresses the manager-to-worker handoff directly while `nodes[]` stays reusable
- `riela` manager nodes use `claude-code-agent`
- the task node `claude-task` also uses `claude-code-agent`
- the bundle includes a deterministic mock scenario for validate/run demos

Validate it:

```bash
riela workflow validate claude-riela-claude-worker --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect claude-riela-claude-worker --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run claude-riela-claude-worker \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/claude-riela-claude-worker/mock-scenario.json \
  --output json
```

### `same-node-session-echo`

Reference workflow for the case where one worker node should run twice:

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` revisits the shared node-registry entry `echo-session` through
  two distinct steps: `echo-request` and `answer-request`
- `nodes/node-echo-session.json` opts into `sessionPolicy.mode = "reuse"`
- the `answer-request` step explicitly inherits that reusable backend session
  from `echo-request`
- the `answer-request` step also switches to the `answer` prompt variant for
  the second visit
- the first visit echoes the normalized request
- the second visit answers using that earlier echo
- the prompt also reads resolved upstream data through
  `{{inbox.latest.output.echoText}}` so the earlier echo is
  available explicitly in workflow data, not only via backend memory

Validate it:

```bash
riela workflow validate same-node-session-echo --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect same-node-session-echo --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run same-node-session-echo \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/same-node-session-echo/mock-scenario.json \
  --output json
```

Live execution note:

- the bundled mock scenario demonstrates the repeated same-node control flow
- actual backend session continuation still depends on the configured
  `claude-code-agent` or `codex-agent` backend returning a reusable session id

### `codex-codex-topic-debate`

Live-agent topic debate bundle for runtime-provided debate prompts. This is the
canonical debate example and replaces the older hard-coded topic variant:

- two `codex-agent` speaker lanes use `gpt-5.3-codex-spark`
- the topic comes from `runtimeVariables.humanInput.request`
- the speaker lanes remain grouped under `workflows/*/nodes/`
- speaker nodes bind `arguments.topic` from the normalized input step
- speakers use node-local `systemPromptTemplateFile` and
  `sessionStartPromptTemplateFile` prompt assets
- output contracts force debate handoff payloads into structured JSON
- `debate-judge` returns business JSON with `continue_debate`; branch routing
  falls back to payload booleans when no adapter `when` flag is present

Validate it:

```bash
riela workflow validate codex-codex-topic-debate --workflow-definition-dir ./examples
```

Run it with live backend execution:

```bash
riela workflow run codex-codex-topic-debate \
  --workflow-definition-dir ./examples \
  --variables '{"humanInput":{"request":"Debate immigration policy. The affirmative side should argue for more open immigration with managed legal pathways, and the negative side should argue for stricter border and asylum controls."}}' \
  --output json
```

Live execution note:

- this bundle depends on the configured `codex-agent` backend honoring the remote request body fields sent by this repository, including `systemPromptText`
