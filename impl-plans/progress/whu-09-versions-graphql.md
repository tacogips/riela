# whu-09-versions-graphql implementation progress

- Dependency `whu-07-coordinator-sync` admitted by runtime `acceptedPlanIds`; plan matches design §4.3.
- Implemented snapshot list, content diff, and dry-run-by-default restore through the GraphQL provider. Applied restore records definition history and returns warnings; invalid input, missing snapshots, dirty conflicts, immutable workflows, and sync failures are mapped to GraphQL errors.
- Direct scope is rejected because this surface has no filesystem path argument and the existing GraphQL scope validation excludes direct; project/direct applied restores remain immutable under the accepted predecessor.
- Executor tests exercise ordering and parent links, content diff, dry-run without writes, applied restore and audit reason, overwritten audit warning, missing snapshot, actor validation, and dirty conflicts. The mutable fixture is used for application as required by predecessor semantics.
- Completion criteria: [x] three operations work through the GraphQL executor; [x] default dry-run and focused tests pass.
- Verification: `build-01.log` exit 0; `tests-final.log` exit 0, 9 tests, 0 failures; `lint-final.log` exit 0, strict selected-file lint. Evidence under `tmp/workflow-history-unification/whu-09-versions-graphql/`. Earlier `tests-01.log` exposed fixture ordering assumptions and `lint-01.log` identified long lines; both corrected and rerun.
- Formal test-integrity, adversarial and integration reviews and final commit are downstream workflow steps.
