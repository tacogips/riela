# GWJSON176-07 progress: docs matrix, contract and scope split

Status: Step 6 implementation complete on `feat/issue-176-gateway-json-remainder`; awaiting independent/integration review and workflow finalization. Issue: [tacogips/riela#176](https://github.com/tacogips/riela/issues/176). Workflow: `opus-luna-design-and-implement-review-loop`, native fanout branch `gwjson176-07`, group `shared-branch-implementation`, index 4. Implementer: Codex primary implementation owner, GPT-6 Luna Step 6.

## Implemented

- Expanded `docs/builtin-gateway-json.md` with the per-family static-validation, failure-metadata and example matrix, including Apple product nodes and Kaiba GraphQL compatibility. Added literal/templated and leaf-view validation behavior, entry-point behavior, common payload contract, exact R2 category precedence, conversion exclusions, labeled branch transitions, finite `project` and `map` forms, R3 Outcome B, example/migration notes, and the explicit implemented-in-riela/outside-riela split.
- Updated `docs/workflows/json-data-processing.md` to use X `selection` field paths, retain `select` as a compatibility alias, and link the X `providerFailure: "output"` behavior.
- Updated `impl-plans/builtin-gateway-json-176.md` to mark requirements 1, 3, 4 and the examples criterion implemented on this branch; outside-riela ART, private-image, App cutover and release/deployment work stays open.
- Updated the active plan status and completion criteria. No source, tests or example files were changed.

## Sources read

- `impl-plans/active/gwjson176-07-docs.md` and `design-docs/specs/design-gateway-sdk-addons.md` (R1/R2/R3/R6).
- `impl-plans/progress/gwjson176-02.md` (R3 Outcome B: SDL only, bounded scanner, 82 operation names; SDK remains type authority).
- `Sources/RielaCLI/XGatewayProviderFailureOutput.swift` (category order and classification conditions).
- `impl-plans/progress/gwjson176-03.md` (R2 implementation/evidence and accepted review).
- `docs/workflows/json-data-processing.md` (finite transform semantics and `project` syntax).
- `examples/x-gateway-json-search/{README.md,workflow.json}`, `examples/notion-gateway-json-sync/README.md`, `examples/builtin-gateway-json/README.md`, `examples/x-window-checkpoint/README.md` (names, operations and labeled transitions).
- `impl-plans/builtin-gateway-json-176.md` and current shared-tree status.

## Source hashes

The first pre-edit hashes are recorded in `tmp/issue-176/gwjson176-07/pre-edit-hashes.txt`; intermediate fresh-read hashes are also appended there. Final hashes are recorded in `tmp/issue-176/gwjson176-07/post-edit-hashes.txt`:

| Path | First pre-edit SHA-256 | Final SHA-256 |
|---|---|---|
| `docs/builtin-gateway-json.md` | `8cf45145e7645aa5ebe38e1c2fbae6f9789a549180425cfd44521cd5ac36943f` | `abe2b351847f38afe9a8af618cbb6374dbf8226743f85b6c27142e22b750e153` |
| `docs/workflows/json-data-processing.md` | `d9f199146076fb41a39b73bdc71f82e5134121d82a29d97e870ee0d077bc46c6` | `5a8b3c32cf6d557c38105b11a85bc2119193b83e93ce2afcd1be600dda8fcb0e` |
| `impl-plans/builtin-gateway-json-176.md` | `a55d5952db022332f11fa691ad3526d6778d87abd0fd473c8c96a8e2dc13496a` | `fcd4fef239a51938291588f8c84b353f70a189937e28b5bf6589e7df53e55cd0` |
| `impl-plans/active/gwjson176-07-docs.md` | `6dd1a9838b17f18ab2d9bc2fec64398bd3e1c01b2581dab53360ed170f40168e` | `71f33d6293e8bc713f3ceaa93432621b8a3e99b7e97e49e95344655b8dd9dbe0` |
| `impl-plans/progress/gwjson176-07.md` | new file | recorded after final update |

Per-edit intended hunks are preserved in `tmp/issue-176/gwjson176-07/edit-intent-001.md` through `edit-intent-005.md`.

## Verification

These are docs-only gates; no behavioral test runner was required. Each current-source command ran in the foreground from the repository root. Every record has `testsRun: 0` and `failureCount: 0`.

| Command | Exit | Tests | Failures | Complete log |
|---|---:|---:|---:|---|
| `grep -n "Implemented in riela vs outside riela" docs/builtin-gateway-json.md > tmp/issue-176/gwjson176-07/split.log` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-07/split.log` |
| `grep -n "providerFailure" docs/builtin-gateway-json.md docs/workflows/json-data-processing.md > tmp/issue-176/gwjson176-07/failure.log` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-07/failure.log` |
| `grep -n "x-gateway-json-search\\|notion-gateway-json-sync" docs/builtin-gateway-json.md > tmp/issue-176/gwjson176-07/examples.log` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-07/examples.log` |
| `grep -n '"project"' docs/builtin-gateway-json.md > tmp/issue-176/gwjson176-07/project.log` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-07/project.log` |
| `git diff --check -- docs/builtin-gateway-json.md docs/workflows/json-data-processing.md impl-plans/builtin-gateway-json-176.md > tmp/issue-176/gwjson176-07/diff-check.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-07/diff-check.log` |

| Relative link command below | 0 | 0 | 0 | `tmp/issue-176/gwjson176-07/relative-links.log` (all 30 links passed) |
| `git diff --check -- docs/builtin-gateway-json.md docs/workflows/json-data-processing.md impl-plans/builtin-gateway-json-176.md impl-plans/active/gwjson176-07-docs.md impl-plans/progress/gwjson176-07.md > tmp/issue-176/gwjson176-07/diff-check-all-final.log 2>&1` | 0 | 0 | 0 | `tmp/issue-176/gwjson176-07/diff-check-all-final.log` |

Exact relative-link command:

```sh
python3 - <<'PY' > tmp/issue-176/gwjson176-07/relative-links.paths
import os, re
from pathlib import Path
text = Path('docs/builtin-gateway-json.md').read_text()
for target in re.findall(r'\]\(([^)]+)\)', text):
    target = target.split('#', 1)[0]
    if not target or target.startswith(('http:', 'https:', 'mailto:', '#')) or target.startswith('/'):
        continue
    print(os.path.normpath(os.path.join('docs', target)))
PY
while IFS= read -r link; do test -e "$link" || { printf 'MISSING %s\n' "$link"; exit 1; }; done < tmp/issue-176/gwjson176-07/relative-links.paths
printf 'test -e passed for %s relative links\n' "$(wc -l < tmp/issue-176/gwjson176-07/relative-links.paths | tr -d ' ')" > tmp/issue-176/gwjson176-07/relative-links.log
```

The first corrected-parser run was exit 1 because the referenced progress self-link did not exist until this file was created; it was rerun above. Full attempt notes are at `tmp/issue-176/gwjson176-07/relative-links-attempt-01.log` and `relative-links-attempt-02.log`. The invalid-parser run that matched zero links is excluded as verification.

## Blockers and residual risks

Blockers: none. The only prerequisite, `gwjson176-03`, is in the assigned item's acceptedPlanIds. Formal test-integrity/adversarial/integration review, index refresh, exact-file staging, commit and push are downstream workflow steps.

Residual risk: `gwjson176-05` may make minimal example fixes after this docs pass; final integration review should confirm the example descriptions still match those changes. No release, installation, ART adoption, App production cutover or deployment is claimed.
