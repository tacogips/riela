# ask-07-web progress

## Implemented

- Mounted the Ask Riela dock in the app shell. Persisted the active conversation and its origin per host/profile. Added route context and entry points in Bots, run details, and the workflow editor.
- Connected the typed GraphQL client, provider/model/effort picker, and the existing Bots polling loop. The picker omits Cursor API and Gemini API instances. The assistant settings support Automatic and link to Models.
- Rendered streamed messages, thoughts, tools, plans, and usage. The settled transcript uses server-verified citations for record links. Proposed actions show explicit Confirm and Dismiss controls and their recorded outcomes.
- Replaced the editor chat with an undoable draft bridge that applies a confirmed definition. Server-side proposal generation remains assigned to ask-06-workflow-authoring.

## Per-edit hashes

Exact hunk intentions and pre/post SHA-256 values are in `tmp/ask-riela/ask-07-web/edit-intentions.md` and `tmp/ask-riela/ask-07-web/edit-hashes.jsonl`. Drift observations against the native pre-implementation snapshot and successive edits: 0.

## Verification

Logs are under `tmp/ask-riela/ask-07-web/`.

| Command | Exit | Log | Result |
| --- | ---: | --- | --- |
| `cd web && bun install --frozen-lockfile` | 0 | `install.log` | 190 installed packages checked |
| `cd web && bun run typecheck` | 0 | `typecheck.log` | TypeScript check passed |
| `cd web && bun test src` | 0 | `test.log` | 163 passed, 0 failed, 39 files |
| `cd web && bun run lint` | 0 | `lint.log` | ESLint and production source audit passed |
| `cd web && bun run build` | 0 | `build.log` | Production bundle built |
| `TMPDIR="$PWD/tmp/ask-riela/ask-07-web/browser-tmp/" bun test tmp/ask-riela/ask-07-web/panel-smoke.test.ts` | 0 | `browser-smoke.log` | 1 passed, 0 failed. Chrome exercised paired-run context, selection, streaming, action decisions, citation navigation, and reload persistence against disposable fixture responses. |
| `grep -rn "WorkflowAgentChat\|workflow-editor/generations" web/src` | 1 | `legacy-grep.log` | 0 bytes, expected no-match exit |
| `git status --porcelain web/package.json web/bun.lock` | 0 | `package-status.log` | 0 bytes |
| `git diff --check -- web/src` | 0 | `diff-check.log` | 0 bytes |

Earlier attempts are retained. `typecheck-tests-first.log` found a possibly undefined test fixture value. `attempts/first-aggregate/test.log` recorded a Bun/Solid JSX import error, resolved by extracting the pure inline tokenizer. `browser-smoke-first.log` timed out on the test's model label locator, which was changed to the model combobox role.

## Deviations

- The Markdown inline tokenizer resolves verified citation markers directly. This keeps model-authored links inert even when they use the same URL as a verified citation.
- A new unsaved workflow sends its draft with a context kind of `none`. A saved workflow uses its registered workflow ID as context.

## Open items

- Test-integrity, adversarial, and serial integration review follow Step 6.
- `web/e2e/workflow-studio.spec.ts` still covers the retired generation REST path and live editor previews. Its disposition belongs to integration because that path sits outside the Step 6 write scope.
