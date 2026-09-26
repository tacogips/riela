# Issue 118: bounded fanout directory change evidence

```json
{
  "planId": "fanout-directory-change-tracking",
  "planPath": "impl-plans/active/fanout-directory-change-tracking.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCore/WorkflowFanoutChangeEvidence.swift",
    "Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift",
    "impl-plans/progress/fanout-directory-change-tracking.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/fanout-directory-change-tracking.md",
  "status": "planned; Step 5 review pending"
}
```

## Intent, authority and boundaries

Mode: `issue-resolution`. Issue: <https://github.com/tacogips/riela/issues/118>.
Source: `design-docs/specs/design-fanout-dependency-waves-and-change-evidence.md`,
especially `Issue #118: bounded directory snapshots`. Step 3 communication
`comm-000004` accepted that design without findings. No Step 5 feedback has been
supplied. No codex-agent references, Cursor adapter mapping or reference
divergences apply.

Users need explicit directory `writePaths` to work after the first dependency
wave and reduce to report newly created and removed descendants. Currently
`snapshot` accepts only regular files and missing paths, and `reduce` snapshots
only recorded file keys. The runner already preflights each selected branch and
captures node boundaries; change only evidence collection/comparison and tests.

Work in the current repository and Git branch
`fix/fanout-directory-change-tracking` (intake HEAD
`fd7d495ad8f02c714f2c5ad9613e8d9fa7d41935`). One plan owns the coupled collector,
reducer and test contract; splitting the same source file into concurrent writers
provides no useful independence. Do not create worktrees or private branches.

Non-goals: scheduler/schema changes, persistent cross-wave actor state, atomic
filesystem snapshots, watchers, locks, generic filesystem frameworks, adapters,
registry discovery, package changes, broad formatting, unrelated validation or
cleanup. Do not release or merge. Source and test changes stay in the two paths
above; documentation/progress are workflow deliverables, not expanded code scope.

## Ownership, evidence and checkpoints

Before fanout, the serial coordinator must obtain Step 5 acceptance, inspect the
exact design/plan diff, then commit the accepted design and this plan and non-force
push the checkpoint. A failed checkpoint push stops dispatch. Step 4 does not
commit a plan before its review. Workers perform no staging, commits or pushes.
No concurrent Git operations are permitted.

Before each edit, freshly read the target and relevant accepted contract. Save
an immutable preimage (or ABSENT), SHA-256 and intent description under
`tmp/issue-118/fanout-directory-change-tracking/<attempt>/<unique-edit>/` using
new names without overwriting earlier evidence. Recheck the hash immediately
before applying a contextual edit; on drift reread and reconcile rather than
restoring a stale file. Save posthash and patch with the requirement/task ID.
Apply this to the worker's progress log as well as source/test files.

Initialize `impl-plans/progress/fanout-directory-change-tracking.md` on worker
start. Only its assigned worker edits it during implementation. Record task
status, changed paths, pre/post hashes, immutable intent paths, exact commands,
complete logs, terminal exit codes, fixture counts, findings and remaining work.
Never mark a failed, skipped or incomplete command as passing. Keep scratch,
fixtures, command wrappers and logs under repository `tmp/issue-118/`; clean
disposable fixtures after use but retain referenced verification evidence through
handoff. No sibling writes or detached shell processes. Poll every yielded command
handle through terminal exit before returning the node.

At join, the serial integration owner compares current hashes to worker posthashes
and every accepted intent. Repair unexpected drift from fresh combined contents,
preserving all accepted behavior; rerun affected checks. Reserve shared indexes,
lockfile generation, broad formatting and global plan archiving for serial
finalization; none is needed for this narrow implementation. Never discard
another actor's edits using reset or checkout.

## Tasks and deliverables

### T1 — Snapshot roots and safely expand directories (no task dependencies)

Edit `Sources/RielaCore/WorkflowFanoutChangeEvidence.swift`:

- Store sorted unique declared roots alongside each captured `files` map, keeping
  original artifact attribution, private permissions and immutable artifact names.
- Retain existing regular-file bytes/hash/mode representation. Add directory
  kind/mode/sorted immediate child names; retain explicit missing declared roots.
  Enumerate every child, including hidden entries and empty directories, in
  deterministic relative-path order. Deduplicate overlapping roots and bytes.
- Validate declared paths and discovered entries. Reject traversal, absolute or
  malformed paths, `.git`, symlink entries/ancestors (including dangling links),
  special files and unreadable entries. Propagate enumeration failures. Only a
  genuinely absent declared root is missing; a child disappearing during its
  traversal is a retryable snapshot failure. Do not swallow ancestor errors.
- Reject roots equal to or containing this actor's evidence directory to avoid
  observing generated artifacts; retain support for unrelated `tmp/` paths.
- Enforce 1...512 declared inputs before deduplication, at most 512 unique
  expanded entries including directories and missing roots, at most 8,000,000
  bytes per file and 64,000,000 total file bytes. Bound traversal incrementally,
  check sizes before reading and actual bytes afterward. Do not publish partial
  evidence on any failure.
- Preserve file identity/size/modification checks; recheck type, mode and symlink
  safety. Recheck directory identity and sorted membership after descendants.
  Detected mutation fails retryably; unsafe entries fail policy validation.
  Keep changes local, using small helpers only when needed. For deterministic
  race/error coverage, a narrowly scoped internal test hook at the observation
  boundary is permissible if necessary; no public API or generic filesystem layer.

Deliverable: directory-aware capture with the original exact-file contract and
safety bounds intact. Acceptance: stable trees capture correctly; unsafe,
over-limit or detected unstable trees fail without publishing partial records.

### T2 — Compare fresh root expansions at reduce (depends on T1)

In the same source file, resnapshot each record's declared roots and compare the
sorted union of old/current entry keys. Keep deterministic branch/record/path
ordering and the join envelope. An absent key and explicit `kind: missing` both
represent absence for drift classification; missing-to-present is `entry-added`,
present-to-missing is `entry-removed`, and missing-to-missing is unchanged.
Then prioritize `entry-kind-drift`, `directory-membership-drift`, and existing
`content-or-mode-drift`. New/deleted descendants each receive path-specific
observations; a changed parent can also receive membership drift. Retain branch,
step and artifact attribution, `hasDrift`, `requiresSemanticReview: true`, and
`observationBoundary: workflow-node`; never put source bytes in joined output.

Deliverable: reduce discovers descendants absent from previous snapshots and
reports deletions, replacements, content and mode changes. Acceptance: late
unsafe entries or limit violations fail reduce using the same snapshot rules;
wave two observes its own current roots without depending on wave one's actor.

### T3 — Focused regression and scale tests (depends on T2)

Edit only `Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift`. Preserve
existing dependency, exact-file overwrite and safety tests. Add assertions on
stored evidence and reduced path/reason/branch observations, not merely success:

| Contract | Required cases |
| --- | --- |
| Directory capture | Nested/hidden files, empty directories, stable no-drift tree, overlap deduplication, retained roots and original bytes |
| Membership | Added/deleted descendants, entire-directory deletion, missing root becoming file/directory, file/directory replacement, empty-directory membership |
| Attribution | Content/mode drift, immutable earlier artifacts, join excludes source bytes |
| Dependency waves | Select wave one, create/populate its directory, accept its branch ID, select wave two and capture the same directory using fresh evidence; assert both wave selection and reduce path/branch observations |
| Safety | Direct/ancestor/dangling symlinks, malformed/traversal/absolute paths, discovered `.git`, special entry such as FIFO without opening it, evidence-directory recursion, enumeration failure |
| Races | Deterministically mutate file identity/content or directory membership between checks; require retryable failure and no new published record, never timing-only stress as proof |
| Bounds | Inclusive/exceeded declared and expanded counts, 8,000,000/8,000,001 file bytes, 64,000,000/64,000,001 aggregate bytes with every file individually valid; duplicate/overlapping roots counted correctly; unsafe and over-limit growth first encountered at reduce |

Use repository-local scratch and teardown. If permissions cannot induce a
reliable enumeration error on the test host, use the minimal internal hook
described in T1 to inject the failure; do not silently skip coverage.

Construct the reported-scale fixture as 60 declared top-level directories: 47
with seven regular files and 13 with six, totaling exactly 407 regular files,
60 directories and 467 unique entries, with zero overlaps. Assert all counts.
Capture wave one, use a fresh wave-two actor, add a file and remove a different
file before reduce, and assert both paths and parent membership drift. Separately
test overlapping selections so this scale case stays easy to audit. The intake
contains no original manifest: identify this as a scale reproduction, not original
package replay. If a manifest is supplied later, record its identity and counts
before replay; no registry searches belong to this task.

### T4 — Verify, self-review and hand off (depends on T3)

Run the commands below serially against the final source/test tree, retaining
complete stdout/stderr and terminal status. Record HEAD and SHA-256 of changed
files with each verification attempt. Inspect the final diff against every task,
fix all material self-review findings and rerun affected checks. Record design
conformance in the progress log; if implementation materially diverges, report
it for review instead of silently editing the accepted contract.

| Command | Required evidence |
| --- | --- |
| `swift test --filter WorkflowFanoutMapReduceTests` | All old and new directory, race, safety, boundary, wave and scale tests execute and pass; retain test counts and fixture counts |
| `swift test --filter DeterministicWorkflowRunnerFanoutTests` | Existing runner fanout integration behavior passes unchanged |
| `swiftlint lint --strict --no-cache Sources/RielaCore/WorkflowFanoutChangeEvidence.swift Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift` | Both changed Swift files pass repository lint configuration; no global formatting |
| `swift build` | Source build and Swift typechecking succeed |
| `git diff --check` | No whitespace errors in final diff |

Use `tmp/issue-118/<attempt>/verification/` for logs and a receipt containing exact
argv, cwd, complete log path and exit code for each command. A wrapper must return
the actual command status; a pipeline logger's success alone is insufficient.
The installed `swiftlint lint --help` accepts positional file paths, not `--path`;
the command above implements the design's explicitly allowed syntax adaptation.
Do not run source gates during planning and report them as implementation proof.

T1/T2 can be explored by read-only investigation independently of test fixture
design, but T1–T4 edits and SwiftPM verification are serial under this owner.
Do not add plans or workers merely to increase concurrency.

## Completion and downstream finalization

Step 6 completion means T1–T4 implemented, all required behavioral/lint/build
checks passing on the handed-off tree, self-review clean, and progress/evidence
complete. Independent adversarial review, combined integration review and final
Git publication are explicitly downstream gates, not reasons to self-block a
complete implementation attempt. Report actual environmental failures with logs;
do not mark incomplete verification as accepted.

After join, the serial owner performs drift repair, independent adversarial and
combined review, and any required documentation refresh, then reruns affected
checks. Resolve every high/mid finding before final commit and non-force push to
`origin fix/fanout-directory-change-tracking`. Review the exact staged file list
and diff; exclude all scratch and unrelated changes. Record commit SHA and push
exit/log. Never release or merge. No source package digest refresh is needed
because this task edits no workflow, prompt, script or skill.

The only evidence limitation inherited from design is absence of the original
60-path/407-file manifest. No unresolved user design decision or reference mapping
blocks this plan. Final workflow completion requires successful downstream review
and publication in addition to implementation acceptance.
