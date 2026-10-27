# ds179-06-docs progress

Status: implementation complete; formal review and workflow finalization are
downstream. Workflow mode: `issue-resolution`. Issue: `tacogips/riela#179`.

## Changes and acceptance criteria

- Added `docs/workflow-definition-store.md`, covering service and one-time
  resolution, first-use seeding, import/force/restore, whole-workflow and prompt
  updates, audit fields and actor kinds, improvement addons and example,
  definition source pins, export, GraphQL fields, and schema generation 10.
- Added `README.md` section `Workflow Definition Store (service vs one-time
  runs)` before Runtime Data Retention with the policy table, CLI examples, and
  guide link.
- Documented that `riela workflow update` remains a file-based mutable-registry
  command; it is not described as a definition-store write. All eight
  documented definition subcommands appear in `riela --help`.

## Edit hashes

| Path | Before | After |
| --- | --- | --- |
| `docs/workflow-definition-store.md` | absent | `d035379eec6531cc79e45f6cafb9b906a370947a2c41c9c4671af8b848335010` |
| `README.md` | `b135714c4879b6d5d8239c6b875fcab211b0150261f04d1c1b9556dbbaa1b8fc` | `bbefdabc60e18358c3504b3d99b95ac2fbf91a4c69c40c93ecfd799a46afcc90` |
| `impl-plans/active/ds179-06-docs.md` | `b85729e53200425101da100937b0a43ad70b33d612f6e386433d361dbba8fd4b` | `dc247e050f5053408e52e342363708df08bd48e7d5deb5924eb1ebf63d2998df` |

## Verification

Every record includes integer exit status, test count and failure count.

| Command | Exit | testsRun | failureCount | Log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-06-docs/build.log 2>&1'` | 0 | 0 | 0 | `tmp/ds179/ds179-06-docs/build.log` |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela --help > tmp/ds179/ds179-06-docs/help.log 2>&1'` | 0 | 0 | 0 | `tmp/ds179/ds179-06-docs/help.log` |
| `grep -c 'riela workflow definition' tmp/ds179/ds179-06-docs/help.log` | 0 | 0 | 0 | `tmp/ds179/ds179-06-docs/retry-1/docs-check.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParitySkillTests > tmp/ds179/ds179-06-docs/skill-parity.log 2>&1'` | 0 | 7 | 0 | `tmp/ds179/ds179-06-docs/skill-parity.log` |
| `grep -o 'riela workflow definition [a-z-]*' docs/workflow-definition-store.md | sort -u` plus exact help membership, section ordering, required-heading, and file-only statement checks | 0 | 0 | 0 | `tmp/ds179/ds179-06-docs/retry-1/docs-check.log` |
| `git diff --check` | 0 | 0 | 0 | `tmp/ds179/ds179-06-docs/retry-1/diff-check.log` |

The focused test log reports `SurfaceParitySkillTests` 7/7 passing. The help
check found all eight subcommands. An initial documentation-check script
returned 1 because its broad regex incorrectly treated the intended file-only
statement about `riela workflow update` as a positive store-write claim; the
check was narrowed to assert the exact file-only wording and then exited 0.
The superseded output is retained at
`tmp/ds179/ds179-06-docs/docs-check.log`.

## Handoff

No implementation blockers or incomplete plan-owned requirements remain.
Formal review, review-dependent documentation/index changes, exact-file
staging, commit, and push are owned by later workflow steps; push is disabled
for this task.
