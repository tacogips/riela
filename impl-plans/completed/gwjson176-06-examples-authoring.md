# GWJSON176-06: script-free X, Notion and extended Gmail example bundles

```json
{
  "planId": "gwjson176-06",
  "planPath": "impl-plans/active/gwjson176-06-examples-authoring.md",
  "dependsOn": ["gwjson176-01"],
  "writePaths": [
    "examples/x-gateway-json-search",
    "examples/notion-gateway-json-sync",
    "examples/builtin-gateway-json",
    "impl-plans/active/gwjson176-06-examples-authoring.md",
    "impl-plans/progress/gwjson176-06.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/gwjson176-06.md",
  "status": "completed 2026-10-25; accepted dependency at fb928672, gwjson176-05 catalog parity passed 9/0 with no example fixes (session-488); archived to impl-plans/completed/"
}
```

## Authority and intent

- Design rule **R4**.
- Issue #176 completion criterion: "X / Gmail / Notion 等の実用 workflow 例で、取得・必要な書き込み・整形に汎用 Python wrapper が不要".

This plan is examples only (JSON and Markdown). It runs in wave 2, in
parallel with gwjson176-02. It depends on gwjson176-01 because that plan's
`WorkflowValidateGatewayContextTests` run validates
`examples/builtin-gateway-json`, and must not see a half-edited bundle.
gwjson176-02 does not validate the bundles this plan edits.

Because it runs beside Swift work, this plan must **not** build Swift. Its
verification uses JSON parsing and the installed `/opt/homebrew/bin/riela`
CLI. Registration in the Swift test catalog and the parity run belong to
gwjson176-05.

Each bundle has:

- `workflow.json`
- a credential-free `mock-scenario.json`
- `README.md`
- `EXPECTED_RESULTS.md`

Each bundle uses only gateway JSON `operation`/`arguments`/`selection`/
`postprocess`, plus `riela/json-transform` for shaping. There are no command,
script, Python, shell, jq or agent nodes.

## Non-goals

- No Swift or test edits, so no `rielaExampleWorkflowNames()` or count change
  (gwjson176-05).
- No edits to other example directories, including `x-window-checkpoint`,
  which keeps its nested `select`.
- No X write (riela has no X writer tier). No new add-ons.
- No gateway-internal pagination. The cursor comes in as `workflowInput` and
  goes out preserved.

## Write ownership

writePaths as in the JSON header; no sharedPaths.

## Bundles

1. **`examples/x-gateway-json-search`** (`workflowId` must equal the directory
   name).
   - Imitate `examples/x-window-checkpoint/workflow.json` (env bindings and
     the `searchPosts` arguments) and `examples/builtin-gateway-json` (style).
   - Node `fetch` is `riela/x-gateway-reader` with this config:
     - `operation: "searchPosts"`;
     - `arguments`: `{query: "{{workflowInput.query}}", maxResults: 25, nextToken: "{{workflowInput.cursor}}"}`;
     - `selection`: `["posts.id","posts.text","posts.createdAt","posts.author.username","pageInfo.nextToken"]`;
     - `postprocess`: pick `/data/searchPosts/posts`, unique `/id`, map
       `{id, text, authorId: "/author/username", publishedAt: "/createdAt"}`,
       take 25;
     - `providerFailure: "output"`.
   - Its env bindings are the same five X credential variables as
     `x-window-checkpoint`, with `required: false`.
   - Step `fetch` has its transitions in this order (first match wins):
     1. label `providerRetryable` → `retry-later`;
     2. label `providerFailed` → `report-failure`;
     3. label `postprocessFailed` → `report-failure`;
     4. unlabeled → `page`.
   - `page`, `retry-later` and `report-failure` are `riela/json-transform`
     nodes (see `docs/workflows/json-data-processing.md`):
     - `page` emits `{items, nextCursor}` from `{{input.processed}}` and
       `{{input.data.searchPosts.pageInfo.nextToken}}`. Use an object `input`
       with exact placeholders and one `project` step.
     - `retry-later` emits `{retryLater: true, category}` from
       `{{input.xGateway.failure.category}}`. It does not loop back.
     - `report-failure` emits the failure category and retryable flag.
   - `mock-scenario.json` mocks only `fetch`, with a payload shaped like the
     embedded reader's output. The GraphQL data goes under `data`:
     `data.searchPosts.posts`, two posts including one with quotes and
     `{{literal}}` text, and `pageInfo.nextToken: "mock-next"`. Use
     `when: {"always": true}`. Copy the real output envelope keys from the
     assertions in `Tests/RielaCLITests/XGatewaySDKAddonTests.swift`.
   - `EXPECTED_RESULTS.md` covers:
     - the mock path: `page` output has 2 items and `nextCursor` `mock-next`;
     - the real-run branches per `when` flag;
     - first-page usage: `{"workflowInput":{"query":"...","cursor":null}}`;
     - passing `nextCursor` as the next run's `cursor`.
2. **`examples/notion-gateway-json-sync`.**
   - Discover operation names from the installed CLI. Record the exact
     commands and outputs in the progress log:
     - `/opt/homebrew/bin/riela addon schema notion-gateway --tier reader --grep '(?i)(query|search|database|page)' --output json`
     - `--tier writer --grep '(?i)create'`
   - If that CLI form fails, run `/opt/homebrew/bin/riela addon schema --help`
     and adapt. Record it. On installed Riela 0.2.60 the `addon schema`
     command is not present; `riela gateway notion --role reader|writer schema`
     and the forwarded Gmail `graphql schema` subcommand provide the operation
     definitions without credentials.
   - Node `query` is `riela/notion-gateway-read`. It uses
     `searchPages(query, startCursor, pageSize)` with the cursor argument
     `"{{workflowInput.cursor}}"`, a
     `selection` that includes the result ids/titles and the next-cursor/
     has-more fields, and a postprocess `pick` + `map` + `take: 10`.
   - Node `create` is `riela/notion-gateway-write`. It uses `createPage` with
     typed arguments produced from `{{input.processed}}` through an exact
     placeholder in `arguments`. The mock uses a fixture parent ID; replace it
     with a page ID connected to the integration for real use. Its postprocess
     picks the created id.
   - Both nodes bind `NOTION_API_KEY` with `fromEnv: NOTION_API_KEY` and
     `required: false`.
   - The mock scenario mocks both nodes.
   - `EXPECTED_RESULTS.md` notes that the write is a single node execution
     with no implicit resend on a postprocess failure, as documented in
     `docs/builtin-gateway-json.md`.
3. **`examples/builtin-gateway-json` (extend; keep `workflowId`).**
   - Keep the `accounts` node unchanged.
   - Add `threads`: `riela/gmail-gateway-reader` with `operation: "threads"`
     and arguments
     `{"input": {"accountId": "{{workflowInput.accountId}}", "first": 10, "after": "{{workflowInput.cursor}}"}}`.
     Confirm the input field names with
     `/opt/homebrew/bin/riela addon schema gmail-gateway --tier reader --grep '(?i)thread'`.
     Selection: `edges.node.id`, `pageInfo.hasNextPage`, `pageInfo.endCursor`.
     Postprocess: pick `/data/threads/edges`, map `{id: "/node/id"}`.
   - Add `draft`: `riela/gmail-gateway-draft` with `operation: "createDraft"`.
     The draft role explicitly rejects `sendMessage` and cannot send mail.
     Use the discovered `SendMessageInput` fields with literal subject and
     deterministic body text. Postprocess picks the returned `draftId`.
   - Chain `accounts` → `threads` → `draft` with unlabeled transitions.
   - The mock scenario mocks all three nodes. `threads` must include
     `pageInfo.endCursor`, following the shape
     `{"edges":[{"node":{"id":..}}],"pageInfo":{"hasNextPage":true,"endCursor":"mock-cursor"}}`
     from `Tests/RielaCLITests/GmailCollectionTests.swift:page`.
   - Update `README.md` and add `EXPECTED_RESULTS.md`.
   - Keep the `GMAIL_GATEWAY_CONFIG` env binding on all Gmail nodes.

## Pitfalls

- Mock runs must pass **without** per-example `--variables`. gwjson176-05's
  parity test passes none. Gateway nodes are mocked, so their templated
  arguments are never rendered. Real `json-transform` nodes may only
  reference `{{input.*}}` values that the mocked upstream payloads contain.
- Transition order matters: labeled transitions come before the unlabeled
  default.
- Do not add `postprocess` steps beyond pick/filter/map/unique/take/project.
- Mock `payload` must not contain secrets. Use fixture ids only.
- The installed CLI (0.2.60) predates `providerFailure`. The key is ignored
  when unknown, and in the mock path the node is mocked, so it is not
  executed.

## Execution rules

- No Swift build or test.
- Fresh-read every file before editing and record pre/post sha256.
- Logs go under `tmp/issue-176/gwjson176-06/`.
- The mock-run session store is `tmp/issue-176/gwjson176-06/sessions-<name>`.

## Verification (each exit 0)

```
mkdir -p tmp/issue-176/gwjson176-06
for f in examples/x-gateway-json-search/*.json examples/notion-gateway-json-sync/*.json examples/builtin-gateway-json/*.json; do python3 -I -m json.tool "$f" > /dev/null || exit 1; done
grep -lE '"riela/(command|bash|python|shell|script)|"command":|"script|python3?[ "]|jq ' examples/x-gateway-json-search/workflow.json examples/notion-gateway-json-sync/workflow.json examples/builtin-gateway-json/workflow.json ; test $? -eq 1
/opt/homebrew/bin/riela workflow validate x-gateway-json-search --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-x.log 2>&1
/opt/homebrew/bin/riela workflow validate notion-gateway-json-sync --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-notion.log 2>&1
/opt/homebrew/bin/riela workflow validate builtin-gateway-json --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-gmail.log 2>&1
/opt/homebrew/bin/riela workflow run x-gateway-json-search --workflow-definition-dir ./examples --mock-scenario ./examples/x-gateway-json-search/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-x --output json > tmp/issue-176/gwjson176-06/run-x.json 2> tmp/issue-176/gwjson176-06/run-x.err
/opt/homebrew/bin/riela workflow run notion-gateway-json-sync --workflow-definition-dir ./examples --mock-scenario ./examples/notion-gateway-json-sync/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-notion --output json > tmp/issue-176/gwjson176-06/run-notion.json 2> tmp/issue-176/gwjson176-06/run-notion.err
/opt/homebrew/bin/riela workflow run builtin-gateway-json --workflow-definition-dir ./examples --mock-scenario ./examples/builtin-gateway-json/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-gmail --output json > tmp/issue-176/gwjson176-06/run-gmail.json 2> tmp/issue-176/gwjson176-06/run-gmail.err
```

Each run's JSON must show `"status":"completed"`. The X run's final `page`
output must contain 2 items and `nextCursor` `mock-next`. Record the observed
fields in the progress log. The grep must find nothing (exit 1). If the
installed CLI cannot run a feature this plan relies on, record a blocker
dependency object for gwjson176-05 instead of changing the design.

## Done criteria

- [x] Three bundles, each with workflow.json, mock-scenario.json, README.md
      and EXPECTED_RESULTS.md.
- [x] All JSON parses. No script or command nodes.
- [x] The installed-CLI validate and mock run exit 0 with status `completed`.
- [x] The progress log records the discovered operation names (commands and
      output log paths) and all verification records with integer exitStatus
      (testsRun 0 and failureCount 0 for non-test commands).

Implementation status: complete for gwjson176-06; pending independent review
and the downstream gwjson176-05 example-catalog registration/parity checks.

## Progress log expectations

`impl-plans/progress/gwjson176-06.md` contains:

- status;
- the operation discovery evidence;
- per-file hashes;
- verification records;
- blockers as dependency objects;
- residual risks (no leading severity word).
