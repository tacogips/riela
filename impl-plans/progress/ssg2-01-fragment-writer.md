# ssg2-01 fragment writer progress

Implementation complete; formal review and integration are pending. The accepted plan aligns with design §§3.1–3.3 and 3.5. No dependencies were required. The production switch remains off; hydration, cascading release and benchmark belong to ssg2-02/03.

- Encoder deterministically hoists qualifying inputSnapshot values, deduplicates transitive fragments, sorts marker digests and honors the literal-reference escape rule.
- Root and nested execution writers insert fragments and references transactionally; both release paths protect referenced fragments, including the aggregate count and deletion. Bound-byte metrics account for fragment texts.
- Writer tests exercise default-off writes, deterministic encoding, small and escaped inputs, shared fragments, terminal first save and transition, digest verification, and nested writes. Generation 11 migration test verifies additive table/index creation and unchanged payload digests.
- Acceptance: default switch has one false declaration; both release functions include reference guards; the writer and migration tests pass. Evidence is `tmp/ssg2/ssg2-01-fragment-writer/acceptance.log` and `test.log`.

SHA-256 before → after (absent means new):

- `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`: absent → `4348b91148e91cf2c44eb00ded23532da389243981bcbdf0b0d987b4306bf03b`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`: `f2e9de362b868c9d198fb908676458273adeb9861df328f321ee70e3404431b2` → `2d5818ed3af5283b1e66658c77a868d85beb5fe2d7e0582ab9102d0a98af8b14`
- `Tests/RielaCoreTests/RuntimePayloadFragmentWriterTests.swift`: absent → `2275244d5fa7a7c978fe06b1391201c0dcd4ecc35ec98c2ac9de7fbd614d5ffd`
- `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`: `9f8c79e596826486b33d238d0148626dd0d8686e2cbd05f795ae22d5b57aed43` → `ccedba225ed2df97ed855bbd54afef66c1e5923e59a0eea81612ec7c4127c1b8`
- This progress file: absent before creation.

Verification on the moving shared tree, all exit 0: plan `swift build` (`build.log`); plan filtered `swift test` (`test.log`, 106 tests, 0 failures); plan selected-file `swiftlint lint --strict` (`plan-lint.log`); exact changed-file manifest lint (`lint.log`); `git diff --check` (`diff-check.log`). Logs reside under `tmp/ssg2/ssg2-01-fragment-writer/`. Earlier build access-control, nested test fixture and lint failures are preserved in `build-attempt-01.log`, `test-attempt-01.log` and `lint-attempt-01.log`; all were corrected and rerun. `build-attempt-02.log` and `test-attempt-02.log` are superseded passes. Final stable integration verification remains downstream.
