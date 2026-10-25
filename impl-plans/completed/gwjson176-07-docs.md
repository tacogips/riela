# GWJSON176-07: gateway JSON docs matrix, contract, migration and the riela/outside-riela split

```json
{
  "planId": "gwjson176-07",
  "planPath": "impl-plans/active/gwjson176-07-docs.md",
  "dependsOn": ["gwjson176-03"],
  "writePaths": [
    "docs/builtin-gateway-json.md",
    "docs/workflows/json-data-processing.md",
    "impl-plans/builtin-gateway-json-176.md",
    "impl-plans/active/gwjson176-07-docs.md",
    "impl-plans/progress/gwjson176-07.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/gwjson176-07.md",
  "status": "completed 2026-10-25; reviews accepted, L-07-1 closed with no doc change needed for 05 (session-488); Step 8 refreshed README.md; archived to impl-plans/completed/"
}
```

## Authority and intent

- Design rule **R6**, the docs plan.
- Acceptance: `docs/builtin-gateway-json.md` and
  `impl-plans/builtin-gateway-json-176.md` show the per-gateway matrix and the
  common contract, and separate what riela implements from the remaining ART
  and deploy work.

This plan is docs only and runs in parallel with gwjson176-04. Every fact it
writes must come from the merged code or from the progress logs of
gwjson176-01, -02, -03 and -06:

- read `impl-plans/progress/gwjson176-02.md` for the R3 outcome (A, B or C);
- read the example names and operations from the gwjson176-06 bundles.

Never claim a release, an installation, ART adoption or deployment.

## Non-goals

- No source, test or example edits.
- No `impl-plans/README.md` index update and no plan archiving; those are
  serial finalization.
- No new design decisions. If code and design disagree, record the
  discrepancy in the progress log as a blocker dependency object.

## Write ownership

writePaths as in the JSON header; no sharedPaths.

## Changes

1. **`docs/builtin-gateway-json.md`.**
   - Status paragraph: what is implemented on this branch, not released.
   - The "Available input surfaces" matrix gains these columns:
     - **Static validation**: what `workflow validate` checks per family,
       following the design R1 table, and what stays runtime-only (Kaiba
       names and types; X argument types unless outcome A).
     - **Failure metadata**: X readers have `providerFailure: "output"`;
       other families say "thrown error, unchanged".
     - **Example**: link the bundle.
   - Replace the "Validation for X readers ... remains runtime-only" text
     with:
     - the literal vs templated rule;
     - the leaf-view rule;
     - the entry-point list: `workflow validate` blocks; `workflow run`
       prints `warning:` lines on stderr without blocking; inspect, catalog,
       task dispatch, the registry, the server, GraphQL and the console stay
       context-free, and the runtime still fails closed.
   - New section **"Common input/output contract"** covering:
     - input keys: `operation`, `arguments`, `selection`, `select` (X
       compatibility alias), `postprocess`, `providerFailure` (X);
     - output: the original payload including cursors, `processed`,
       `postprocess.status` (`ok`/`failed`/`skipped`), and the when-flags
       `postprocessPassed`/`postprocessFailed`, plus `providerFailed`,
       `providerRetryable`, `spendCapReached` and `rateLimited` in X output
       mode.
   - New section **"X provider failure output"** covering:
     - the category table, copied from
       `Sources/RielaCLI/XGatewayProviderFailureOutput.swift:classify`, in
       the same rule order;
     - which errors are never converted;
     - "retryable is advice; riela never retries (`--retry 0`)";
     - a branch example with labeled transitions.
   - The "Finite postprocess" table gains `project` and the `map` field forms
     (`path`/`default`, `literal`), matching
     `docs/workflows/json-data-processing.md`.
   - New section **"X request path (#176 requirement 3)"** covering:
     - the R3 outcome from the gwjson176-02 log;
     - kept code and why;
     - retired paths (none, unless outcome A deleted the serializer);
     - the `select` → `selection` migration rule with one example;
     - "no X Python helper exists in riela".
   - Examples list: `x-gateway-json-search`, `notion-gateway-json-sync`,
     `builtin-gateway-json` (accounts → threads → draft), and
     `x-window-checkpoint` (checkpointed cursor).
   - Migration notes:
     - X `select` → `selection`;
     - opting in to `providerFailure: "output"`;
     - X request errors are `policyBlocked` (already documented; keep);
     - the Google Service `allPages` compatibility note.
   - New section **"Implemented in riela vs outside riela"** with two lists:
     - riela: R1-R5 with links to tests and examples;
     - outside riela, not done here: ART Python migration, private image
       adoption, App production cutover, release/deploy.
2. **`docs/workflows/json-data-processing.md`.**
   - Change the X example's nested `select` to `selection` field paths and add
     a one-line compatibility note for `select`.
   - Add a sentence on `providerFailure: "output"` that links to
     builtin-gateway-json.md.
   - Do not change the json-transform semantics text.
3. **`impl-plans/builtin-gateway-json-176.md`.**
   - Under "What remains of #176, by requirement", mark Requirement 1,
     Requirement 3, Requirement 4 and the examples criterion as implemented
     on `feat/issue-176-gateway-json-remainder`. Link the gwjson176-0N
     progress logs.
   - Keep the outside-riela items (ART Python removal, private image, App
     cutover, release/deployment acceptance) listed as open.
   - Do not rewrite historical checkpoints.

## Pitfalls

- Copy the category rule order exactly from the source file; do not
  paraphrase the order.
- State the R3 outcome as recorded. If the gwjson176-02 log is missing it,
  record a blocker dependency object instead of guessing.
- Riela 0.2.45 / PR #177 history stays as written.

## Verification (each exit 0)

```
mkdir -p tmp/issue-176/gwjson176-07
grep -n "Implemented in riela vs outside riela" docs/builtin-gateway-json.md > tmp/issue-176/gwjson176-07/split.log
grep -n "providerFailure" docs/builtin-gateway-json.md docs/workflows/json-data-processing.md > tmp/issue-176/gwjson176-07/failure.log
grep -n "x-gateway-json-search\|notion-gateway-json-sync" docs/builtin-gateway-json.md > tmp/issue-176/gwjson176-07/examples.log
grep -n '"project"' docs/builtin-gateway-json.md > tmp/issue-176/gwjson176-07/project.log
git diff --check -- docs/builtin-gateway-json.md docs/workflows/json-data-processing.md impl-plans/builtin-gateway-json-176.md > tmp/issue-176/gwjson176-07/diff-check.log 2>&1
```

Also check by hand, and record in the progress log, that every relative link
added in `docs/builtin-gateway-json.md` resolves to an existing path
(`test -e` per link).

## Done criteria

- [x] All grep checks find matches (exit 0), and `git diff --check` exits 0.
- [x] The matrix covers every family in the design R1 table, plus the Apple
      product nodes and Kaiba GraphQL compatibility rows that already exist.
- [x] The outside-riela list is present and makes no deployment claim.
- [x] The progress log has verification records with integer exitStatus,
      testsRun 0 and failureCount 0, plus per-edit hashes.

## Step 6 implementation state

The docs-only acceptance criteria are implemented on
`feat/issue-176-gateway-json-remainder`. Verification records, current hashes
and relative-link existence checks are in `impl-plans/progress/gwjson176-07.md`.
Independent review, shared-tree integration review, index refresh, exact-file
staging, commit and push remain downstream workflow steps.

## Progress log expectations

`impl-plans/progress/gwjson176-07.md` contains:

- status;
- the sources each fact was read from;
- per-edit hashes;
- verification records;
- blockers as dependency objects;
- residual risks (no leading severity word).
