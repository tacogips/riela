# ssg4-01 release cascade and benchmark progress

Status (2026-10-30): completed and accepted by the test-integrity, adversarial and integration reviews in session 566. The "remain downstream" wording below records the state at implementation time.

Implementation completed; formal integrity, adversarial and integration review remain downstream. The plan has no dependencies and aligns with design §§3.2, 3.5 and 3.6. The existing default is `true`. Inspection confirmed all three root-scoped release guards, insertion before release, recursive guarded child release and two bounded sweep rounds. No production edits were needed. The operator's renamed writer test correctly pins both full and reduced modes and was preserved.

Added the default-mode writer assertion, six release tests for rewrite, truncation, nested replacement, terminal save, leaked refs and root isolation, and the 24-execution stored-JSONB benchmark including each execution's 16 KiB output and reduced refs overhead. The benchmark reports baseline 4,923,178 bytes, reduced 859,707 bytes, ratio 5.73. Root-scoped invariant checks cover dangling parents, dangling children and unreferenced payloads.

Conditional test decisions: no edits or form pins were needed in `RuntimePayloadReadParityTests.swift`, `SQLiteRuntimeExecutionRowsTests.swift`, `RuntimePersistenceBoundedWriteTests.swift`, `RuntimePayloadHydrationTests.swift` or `SQLiteRuntimeSchemaMigrationTests.swift`; the required suites passed unchanged.

Final-source verification: arm64 `swift build` exit 0; required aggregate `swift test` exit 0 (407 tests, one skipped, zero failures); layout filter exit 0 (20 tests, zero failures); benchmark grep exit 0; plan lint and NUL-manifest changed-file strict lint exit 0. Logs, command output, per-edit intentions and SHA-256 evidence are under `tmp/ssg4/ssg4-01-release-cascade-benchmark/`. Initial focused attempts exposed a fixture compile error and invalid child status; both were corrected, and the focused suite subsequently passed. An initial lint line-length failure was corrected before the final gates. Formal reviews and final commit belong to subsequent workflow steps.
