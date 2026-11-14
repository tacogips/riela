# P1-7a receiving-service publication decision

Status: resolved by current effective workflow input (2026-09-25). Workflow mode: `issue-resolution`.

Current decision: use Riela's native GraphQL receiving boundary already merged
at `a373a6040bff11ef7e86b8f6789321fefc7596f1`. Step 1 `comm-000002` for
“Finish Work Runtime P1-7a legacy supervision removal on native Riela receiving
boundary” supplies this authority. No archived `rielflow` edit or publication is
a dependency. Fresh native rejection (including false/null), opaque-variable
preservation and authenticated ordinary-request evidence belong to P1-7a A3;
A4 independent review has accepted the source-matched evidence and baseline
attribution for both failed broad Swift aggregates. Step 7b browser E2E was
skipped because no `web/` file changed. A5 exact-file publication to Draft PR
#109 and parent P1 remain separate open gates. See the current continuation in
`design-docs/specs/design-work-runtime-consolidation.md` §17.10 and
`design-docs/specs/design-native-remote-workflow-execution.md`.

## Historical question (superseded; no decision pending)
Issue: “Resume P1-7a after reviewed failure-policy amendment”; effective
`workflowInput` / `comm-000001`, intake `comm-000002`, execution
`codex-design-and-implement-review-loop-session-1`. No issue URL/number supplied.

The receiving owner is `tacogips/rielflow`; HTTP GraphQL `ExecuteWorkflowInput`
lives in `packages/rielflow-graphql/src/schema-contract.ts`. The intake reports
local branch `feat/p1-7a-remote-field-rejection` at `c2b16ab`, 91 passing related
tests plus typecheck/build, and three separately reproduced non-schema full-suite
failures. GitHub rejected push with HTTP 403 because the repository is archived.
These external results are reported, not independently rerun in Step 2.

Decision needed: should the owner unarchive this repository and publish the
reviewed change, or select a replacement receiving repository/service? No option
is selected and no publication is authorized by this document. A replacement
requires explicit owner/path and publication direction before external edits.

Local A1 may proceed through its reviewed gates. A2/A3 acceptance and P1-7a
closure require published receiving-side rejection of both retired fields,
including false/null presence, and ordinary authenticated-request acceptance.
Record published source/service identity, exact test paths/commands, complete
logs and terminal exits. Local `c2b16ab` is not remote integration evidence.
Parent P1 remains open for its separate audit. See
`design-docs/specs/design-work-runtime-consolidation.md` §17.10.
