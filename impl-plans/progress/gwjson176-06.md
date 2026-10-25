# gwjson176-06 progress

## Status

Implementation is complete for assigned plan `gwjson176-06`, including review
repair GW176-06-AR-1, on branch `feat/issue-176-gateway-json-remainder`.
Dependency `gwjson176-01` is admitted
by runtime-owned `acceptedPlanIds: ["gwjson176-01"]`. No blocker remains.
Independent review and `gwjson176-05` catalog registration/parity verification
are downstream workflow work.

## Delivered bundles

- `examples/x-gateway-json-search`: X `searchPosts`, all five optional X env
  bindings, `providerFailure: "output"`, ordered retryable/provider-failure/
  postprocess-failure/default branches, finite pick/unique/map/take shaping,
  and a mock page with two posts (one preserves quotes and `{{literal}}`) and
  `pageInfo.nextToken`.
- `examples/notion-gateway-json-sync`: cursor-bearing `searchPages`, finite
  pick/map/take/pick shaping, an exact-placeholder typed `createPage` request,
  and mock read/write payloads. The read output retains `has_more` and
  `next_cursor` alongside `processed` in the runtime session record. The
  example uses a fixture parent page ID that must be replaced for real use.
- `examples/builtin-gateway-json`: kept the existing `accounts` node config,
  then added `threads` with `input.accountId`, `first`, and `after` cursor, plus
  a draft-only `createDraft` operation. All Gmail nodes bind optional
  `GMAIL_GATEWAY_CONFIG`. Mock page includes `pageInfo.endCursor`.

Each directory has `workflow.json`, `mock-scenario.json`, `README.md`, and
`EXPECTED_RESULTS.md`. Workflow JSON contains no command/script/Python/shell/jq
or agent nodes. Mock scenarios contain fixture data only.

## Operation discovery

`/opt/homebrew/bin/riela --version` exited 0 and reported `0.2.60`
(`version.log`). The plan's `addon schema` syntax is not available in this
CLI. These exact discovery attempts exited 2 with complete output in the
listed logs:

- `/opt/homebrew/bin/riela addon schema notion-gateway --tier reader --grep '(?i)(query|search|database|page)' --output json` — `discover-notion-reader.log`.
- `/opt/homebrew/bin/riela addon schema notion-gateway --tier writer --grep '(?i)create' --output json` — `discover-notion-writer.log`.

`/opt/homebrew/bin/riela addon schema --help` exited 0 and showed no
`addon schema` subcommand (`discover-help.log`). Adapted provider-owned schema
commands succeeded:

| Exact command | Exit | Discovered contract | Full output |
| --- | ---: | --- | --- |
| `/opt/homebrew/bin/riela gateway notion --role reader` | 0 | `searchPages` accepts `query`, `startCursor`, `pageSize`; | `gateway-notion-reader.log` |
| `/opt/homebrew/bin/riela gateway notion --role reader schema` | 0 | reader SDL includes `searchPages(query: String, startCursor: String, pageSize: Int): JSON`; | `discover-notion-reader-schema.log` |
| `/opt/homebrew/bin/riela gateway notion --role writer schema` | 0 | writer supports `createPage(parentId: ID!, title: String!, children: JSON, markdown: String, position: JSON)`; | `discover-notion-writer-schema.log` |
| `/opt/homebrew/bin/riela gateway gmail --role reader` | 0 | reader supports `threads`; | `gateway-gmail-reader.log` |
| `/opt/homebrew/bin/riela gateway gmail --role reader graphql schema` | 0 | `threads(input: ThreadSearchInput!)`; input has `accountId`, `first`, `after`; | `discover-gmail-reader-schema.log` |
| `/opt/homebrew/bin/riela gateway gmail --role draft` | 0 | role is draft-only and cannot send mail; | `gateway-gmail-draft.log` |
| `/opt/homebrew/bin/riela gateway gmail --role draft graphql schema` | 0 | mutation `createDraft(input: SendMessageInput!)`; fields include `accountId`, `to`, `subject`, `textBody`; | `discover-gmail-draft-schema.log` |

The plan's suggested `sendMessage` draft operation conflicts with the installed
role contract: the draft binary rejects `sendMessage` before dispatch and can
never send mail. The example therefore uses the supported `createDraft`, which
meets the intended one-write draft flow and least-authority role boundary. Full
role listings are in `gateway-list.log`, `gateway-notion-help.log`, and
`gateway-gmail-draft-help.log`.

## File identity

Pre-edit hashes for existing owned sources and accepted design/plan references
are recorded in `tmp/issue-176/gwjson176-06/pre-edit-sha256.txt`; edit intents
are in `tmp/issue-176/gwjson176-06/edit-intents.md`. Post-edit hashes for all
12 example files and the active plan are in
`tmp/issue-176/gwjson176-06/post-edit-sha256.txt`. Existing owned files were
fresh-read immediately before their edits. `examples/x-window-checkpoint` was
read as a reference and left unchanged.

## Final verification

The following table records the initial Step 6 verification. The X and Gmail
bundles remain byte-identical after GW176-06-AR-1 and their evidence remains
source-matched. The earlier Notion validation/run/assertion entries are
superseded by the repair verification below. Non-test checks report `testsRun:
0` and `failureCount: 0`.

| Exact command | exitStatus | testsRun | failureCount | Complete logPath(s) |
| --- | ---: | ---: | ---: | --- |
| `for f in examples/x-gateway-json-search/*.json examples/notion-gateway-json-sync/*.json examples/builtin-gateway-json/*.json; do python3 -I -m json.tool "$f" > /dev/null || exit 1; done > tmp/issue-176/gwjson176-06/json-parse-final.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/json-parse-final.log` |
| `grep -lE '"riela/(command|bash|python|shell|script)|"command":|"script|python3?[ "]|jq ' examples/x-gateway-json-search/workflow.json examples/notion-gateway-json-sync/workflow.json examples/builtin-gateway-json/workflow.json > tmp/issue-176/gwjson176-06/script-node-scan-final.log 2>&1; grep_status=$?; if [ "$grep_status" -eq 1 ]; then exit 0; else exit 1; fi` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/script-node-scan-final.log` |
| `/opt/homebrew/bin/riela workflow validate x-gateway-json-search --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-x-final.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/validate-x-final.log` |
| `/opt/homebrew/bin/riela workflow validate notion-gateway-json-sync --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-notion-final.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/validate-notion-final.log` |
| `/opt/homebrew/bin/riela workflow validate builtin-gateway-json --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-gmail-final.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/validate-gmail-final.log` |
| `/opt/homebrew/bin/riela workflow run x-gateway-json-search --workflow-definition-dir ./examples --mock-scenario ./examples/x-gateway-json-search/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-x-final --output json > tmp/issue-176/gwjson176-06/run-x-final.json 2> tmp/issue-176/gwjson176-06/run-x-final.err` | 0 | 1 | 0 | `tmp/issue-176/gwjson176-06/run-x-final.json`; `tmp/issue-176/gwjson176-06/run-x-final.err` |
| `/opt/homebrew/bin/riela workflow run notion-gateway-json-sync --workflow-definition-dir ./examples --mock-scenario ./examples/notion-gateway-json-sync/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-notion-final-final --output json > tmp/issue-176/gwjson176-06/run-notion-final-final.json 2> tmp/issue-176/gwjson176-06/run-notion-final-final.err` | 0 | 1 | 0 | `tmp/issue-176/gwjson176-06/run-notion-final-final.json`; `tmp/issue-176/gwjson176-06/run-notion-final-final.err` |
| `/opt/homebrew/bin/riela workflow run builtin-gateway-json --workflow-definition-dir ./examples --mock-scenario ./examples/builtin-gateway-json/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-gmail-final --output json > tmp/issue-176/gwjson176-06/run-gmail-final.json 2> tmp/issue-176/gwjson176-06/run-gmail-final.err` | 0 | 1 | 0 | `tmp/issue-176/gwjson176-06/run-gmail-final.json`; `tmp/issue-176/gwjson176-06/run-gmail-final.err` |
| `python3 -I tmp/issue-176/gwjson176-06/assertions-final.py > tmp/issue-176/gwjson176-06/assertions-final.log 2>&1` | 0 | 10 | 0 | `tmp/issue-176/gwjson176-06/assertions-final.log` |
| `sha256sum -c tmp/issue-176/gwjson176-06/post-edit-sha256.txt > tmp/issue-176/gwjson176-06/hash-check-final.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/hash-check-final.log` |

Observed outputs: all runs have `status: completed`, and every executed node is
completed. X root output has 2 items, preserves the quoted `{{literal}}` text,
and has `nextCursor: "mock-next"`. Notion's query receipt has
`has_more: true` and `next_cursor: "mock-notion-next"`, and its write output
has `processed: "fixture-created-page"`. Gmail executes `accounts → threads →
draft` and the draft output is `"fixture-draft"`. Assertion details are in
`assertions-final.log`.

No Swift build, test, or lint command was run: this plan owns examples only.

## Superseded attempts

- The initial Notion mock run exited 1 because `prepare` tried to resolve
  `input.processed.0.title`; the CLI template resolver does not traverse dotted
  array indexes. Log: `run-notion.err`.
- The second Notion mock run exited 1 because a direct
  `input.data.searchPages.results.0.title` template also failed resolution.
  Session export showed the mock payload had a processed result array and the
  native cursor. Log: `run-notion-final.err`; exported evidence:
  `notion-session-export.json`.
- The final workflow uses a permitted `pick /0/title` postprocess to produce a
  scalar `processed` title, then consumes it as exact `{{input.processed}}`.
  The final Notion validate and mock run both exit 0 as listed above.
- Initial schema commands and help adaptation are recorded above; no final
  verification gate remains failed.

## Blockers and residual risks

Blockers: none. No credentialed provider run was performed. The installed
0.2.60 CLI predates the `providerFailure` runtime option, so X failure routing
is configured and mock-path validated here; live provider failure behavior is
owned by the Swift runtime implementation and its later verification. The new
example names and mock count still require downstream `gwjson176-05`
registration/parity review.

## Adversarial repair: GW176-06-AR-1 (comm-008875)

Severity fixed. The mock now matches native Notion search output:
`data.searchPages.object` is `list`; each result is a `page` with its title at
`properties.title.title[0].plain_text`; `has_more` and `next_cursor` remain
present. The query map reads `/properties/title/title/0/plain_text` and uses
`Untitled` when that property is absent, then `pick /0/title` passes the
non-null title to `prepare` and the required `createPage.title` argument.
Selection remains as planned; documentation does not claim it filters the
JSON-scalar response.

Evidence checked: `.build/checkouts/notion-gateway/Sources/NotionGatewayCore/NotionGatewaySDK.swift:136` returns the decoded native value;
`NotionRequestBuilder.swift` constructs searchPages as the Notion search body
and requires `createPage.title`. `Sources/RielaCLI/JSONDataTransform.swift`
supports `{path, default}` map selectors. The provider response shape now
matches those contracts.

Repair hashes: pre-edit values for all four Notion files are in
`tmp/issue-176/gwjson176-06/pre-repair-sha256.txt`; repaired values are in
`post-repair-sha256.txt`. The regenerated
`tmp/issue-176/gwjson176-06/post-edit-sha256.txt` covers all 12 example files
plus the active plan. X and Gmail file hashes match their original values;
`protected-bundles-ar1.log` records the check. The full hash check is in
`hash-check-ar1.log`.

Current-source verification records:

| Exact command | exitStatus | testsRun | failureCount | Complete logPath(s) |
| --- | ---: | ---: | ---: | --- |
| `for f in examples/notion-gateway-json-sync/*.json; do python3 -I -m json.tool "$f" > /dev/null || exit 1; done > tmp/issue-176/gwjson176-06/json-parse-ar1.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/json-parse-ar1.log` |
| `grep -lE '"riela/(command|bash|python|shell|script)|"command":|"script|python3?[ "]|jq ' examples/notion-gateway-json-sync/workflow.json > tmp/issue-176/gwjson176-06/script-scan-ar1.log 2>&1; test $? -eq 1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/script-scan-ar1.log` |
| `/opt/homebrew/bin/riela workflow validate notion-gateway-json-sync --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-notion-ar1.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/validate-notion-ar1.log` |
| `/opt/homebrew/bin/riela workflow run notion-gateway-json-sync --workflow-definition-dir ./examples --mock-scenario ./examples/notion-gateway-json-sync/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-notion-ar1 --output json > tmp/issue-176/gwjson176-06/run-notion-ar1.json 2> tmp/issue-176/gwjson176-06/run-notion-ar1.err` | 0 | 1 | 0 | `tmp/issue-176/gwjson176-06/run-notion-ar1.json`; `tmp/issue-176/gwjson176-06/run-notion-ar1.err` |
| `python3 -I tmp/issue-176/gwjson176-06/assertions-ar1.py > tmp/issue-176/gwjson176-06/assertions-ar1.log 2>&1` | 0 | 16 | 0 | `tmp/issue-176/gwjson176-06/assertions-ar1.log` |
| `grep -E 'examples/(x-gateway-json-search|builtin-gateway-json)/' tmp/issue-176/gwjson176-06/post-edit-sha256.txt > tmp/issue-176/gwjson176-06/protected-bundles-ar1.sha256 && sha256sum -c tmp/issue-176/gwjson176-06/protected-bundles-ar1.sha256 > tmp/issue-176/gwjson176-06/protected-bundles-ar1.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/protected-bundles-ar1.log` |
| `sha256sum -c tmp/issue-176/gwjson176-06/post-edit-sha256.txt > tmp/issue-176/gwjson176-06/hash-check-ar1-final.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/hash-check-ar1-final.log` |

The repaired Notion mock completed. Assertions verify the native list/page
shape, `query.processed == "Mock page to sync"`, non-null
`prepare.value.arguments.title == "Mock page to sync"`, preserved cursor, and
`create.processed == "fixture-created-page"`. `run-notion-ar1.err` is empty.
All X and Gmail assertions still pass against their unchanged, hash-verified
files and prior successful CLI receipts.

The following fresh combined-bundle verification ran after the Notion repair;
it confirms X and Gmail remain green on the same current tree:

| Exact command | exitStatus | testsRun | failureCount | Complete logPath(s) |
| --- | ---: | ---: | ---: | --- |
| `for f in examples/x-gateway-json-search/*.json examples/notion-gateway-json-sync/*.json examples/builtin-gateway-json/*.json; do python3 -I -m json.tool "$f" > /dev/null || exit 1; done > tmp/issue-176/gwjson176-06/json-parse-all-ar1.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/json-parse-all-ar1.log` |
| `grep -lE '"riela/(command|bash|python|shell|script)|"command":|"script|python3?[ "]|jq ' examples/x-gateway-json-search/workflow.json examples/notion-gateway-json-sync/workflow.json examples/builtin-gateway-json/workflow.json > tmp/issue-176/gwjson176-06/script-scan-all-ar1.log 2>&1; grep_status=$?; if [ "$grep_status" -eq 1 ]; then exit 0; else exit 1; fi` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/script-scan-all-ar1.log` |
| `/opt/homebrew/bin/riela workflow validate x-gateway-json-search --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-x-ar1.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/validate-x-ar1.log` |
| `/opt/homebrew/bin/riela workflow validate builtin-gateway-json --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-06/validate-gmail-ar1.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-06/validate-gmail-ar1.log` |
| `/opt/homebrew/bin/riela workflow run x-gateway-json-search --workflow-definition-dir ./examples --mock-scenario ./examples/x-gateway-json-search/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-x-ar1 --output json > tmp/issue-176/gwjson176-06/run-x-ar1.json 2> tmp/issue-176/gwjson176-06/run-x-ar1.err` | 0 | 1 | 0 | `tmp/issue-176/gwjson176-06/run-x-ar1.json`; `tmp/issue-176/gwjson176-06/run-x-ar1.err` |
| `/opt/homebrew/bin/riela workflow run builtin-gateway-json --workflow-definition-dir ./examples --mock-scenario ./examples/builtin-gateway-json/mock-scenario.json --session-store tmp/issue-176/gwjson176-06/sessions-gmail-ar1 --output json > tmp/issue-176/gwjson176-06/run-gmail-ar1.json 2> tmp/issue-176/gwjson176-06/run-gmail-ar1.err` | 0 | 1 | 0 | `tmp/issue-176/gwjson176-06/run-gmail-ar1.json`; `tmp/issue-176/gwjson176-06/run-gmail-ar1.err` |
| `python3 -I tmp/issue-176/gwjson176-06/assertions-ar1.py > tmp/issue-176/gwjson176-06/assertions-ar1.log 2>&1` | 0 | 16 | 0 | `tmp/issue-176/gwjson176-06/assertions-ar1.log` |

All three workflow validations report `valid: true` with empty diagnostics; all
three mock runs complete. The combined assertions verify native Notion page
shape/title, non-null create title, preserved cursors, and the X/Gmail outputs.
