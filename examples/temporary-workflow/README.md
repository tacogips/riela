# Temporary Workflow Example

## Register For Reuse

The current Swift CLI can persist a normal workflow JSON file or bundle as a
user-scoped temporary workflow:

```bash
riela workflow register ./path/to/workflow-bundle --temporary --output jsonl
riela workflow list --output table
riela workflow list --exclude-temporary --output jsonl
riela workflow validate <workflowId> --output jsonl
riela workflow run <workflowId> --mock-scenario ./path/to/mock.json --output jsonl
```

Use `--overwrite` to replace the managed copy. Registration performs full
bundle validation before publishing and stores the result below
`~/.riela/temporary-workflows/<workflowId>/`. `workflow list [query]` performs a
case-insensitive workflow/package-name substring match. Registered temporary
workflows are the lowest-precedence local resolution source.

The checked-in `temp-workflow.json` below demonstrates the older one-shot
embedded payload form. It is intentionally distinct from persistent
registration: its wrapper JSON is executed directly and is not added to the
workflow catalog.

This example is a temporary workflow payload, not an installed workflow bundle.
It can run directly from JSON without copying anything into project or user
workflow scope.

The payload is stored in `temp-workflow.json` and uses the temporary workflow
format:

- `workflow`: the authored step-addressed workflow definition
- `nodePayloads`: embedded node payloads keyed by the node file path referenced
  from `workflow.nodes[]`

Temporary workflow payloads must embed prompt content directly in JSON. Do not
use `promptTemplateFile`, `systemPromptTemplateFile`,
`sessionStartPromptTemplateFile`, external `stepFile`, or unresolved external
node files in a temporary workflow payload.

## Run From JSON File

Use `--dry-run` when you want to verify loading, validation, source metadata, and
payload logging without calling an agent backend:

```bash
riela workflow run \
  --workflow-json-file ./examples/temporary-workflow/temp-workflow.json \
  --dry-run \
  --output json \
  --artifact-root ./tmp/temporary-workflow-example/file-artifacts \
  --session-store ./tmp/temporary-workflow-example/file-sessions
```

Remove `--dry-run` to execute the embedded `codex-agent` worker.

## Run From Inline JSON

The same payload can be passed inline. This command reads the checked-in JSON
file into a shell variable and sends it through `--workflow-json`:

```bash
temporary_workflow_json="$(
  bun -e 'const fs = require("node:fs"); process.stdout.write(fs.readFileSync("examples/temporary-workflow/temp-workflow.json", "utf8"));'
)"

riela workflow run \
  --workflow-json "$temporary_workflow_json" \
  --dry-run \
  --output json \
  --artifact-root ./tmp/temporary-workflow-example/inline-artifacts \
  --session-store ./tmp/temporary-workflow-example/inline-sessions
```

## Inspect Payload Logs

Temporary runs persist the submitted and normalized payload under the run
artifact tree:

```bash
find ./tmp/temporary-workflow-example \
  -path '*/temporary-workflow-payload/*' \
  -type f \
  | sort
```

Expected files include:

- `temporary-workflow-payload/input.json`
- `temporary-workflow-payload/normalized.json`
- `temporary-workflow-payload/metadata.json`

Normal project, user, explicit-directory, manifest, and registry workflow runs
do not create this directory.
