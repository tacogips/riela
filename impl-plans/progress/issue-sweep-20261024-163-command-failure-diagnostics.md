# ISW-163 implementation progress

Issue: `tacogips/riela#163`  
Plan: [completed implementation plan](../completed/issue-sweep-20261024-163-command-failure-diagnostics.md)  
Design: [command failure diagnostics](../../design-docs/specs/design-command-failure-diagnostics.md)

## Implementation

- Added the opt-in `WorkflowFailureDiagnostics` restricted schema reader and
  wired the optional policy through `WorkflowCommandExecution` Codable.
- Added an optional stdout byte cap to the local process reader. It drains all
  bytes but retains and streams only the configured prefix. The command
  executor uses a 65,537-byte sentinel cap only with a policy, emits one
  non-authoritative receipt on nonzero exit, and preserves the original
  provider error. Oversized exit-zero output fails before output acceptance.
- Restricted runtime-store metadata retention to
  `command_failure_diagnostics`; added adapter and store regression coverage,
  the README explanation and the ported implementation note.
- Existing `inheritEnvironment: false` is retained.

## Per-edit evidence

All pre-edit hashes and exact behavior intentions are stored under
`tmp/issue-sweep-20261024/ISW-163/`. For each edited source, the named `.pre`
hash is its original content; the `.post`/`.final` hash is its post-edit
content. For multiple edits to one file, the next pre-edit hash records the
previous edit's resulting content.

| Path | Pre-edit SHA-256 evidence | Post-edit SHA-256 evidence |
| --- | --- | --- |
| `Sources/RielaCore/WorkflowModel.swift` | `WorkflowModel.pre.sha256` | `WorkflowModel.final.sha256` |
| `Sources/RielaCore/WorkflowFailureDiagnostics.swift` | absent (`WorkflowFailureDiagnostics.pre.sha256`) | `WorkflowFailureDiagnostics.final.sha256` |
| `Sources/RielaAdapters/LocalProcess.swift` | `LocalProcess.pre.sha256` | `LocalProcess.final.sha256` |
| `Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift` | `WorkflowStdioNodeExecutor.pre.sha256` | `WorkflowStdioNodeExecutor.post.sha256` |
| `Sources/RielaCore/RuntimeStore.swift` | `RuntimeStore.pre.sha256` | `RuntimeStore.final.sha256` |
| `Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift` | absent, then each `.pre-*.sha256` before the successive patches | `CommandFailureDiagnosticsTests.final.sha256` |
| `Tests/RielaCoreTests/RuntimeStoreTests.swift` | `RuntimeStoreTests.pre.sha256` | `RuntimeStoreTests.final.sha256` |
| `README.md` | `README.pre.sha256`, then `README.pre-wording-fix.sha256` | `README.final.sha256` |
| `impl-plans/command-failure-metadata.md` | absent (`command-failure-metadata.pre.sha256`) | `command-failure-metadata.final.sha256` |
| This progress record | absent (`progress.pre.sha256`) | written after verification records below |

## Verification

Commands ran from the repository root through ARM64 zsh. Logs are complete and
end with integer `exitStatus` values.

| Command | exitStatus | testsRun | failureCount | Log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-20261024/ISW-163/build-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/build-final.log'` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-163/build-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter CommandFailureDiagnosticsTests > tmp/issue-sweep-20261024/ISW-163/cfd-final2.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/cfd-final2.log'` | 0 | 7 | 0 | `tmp/issue-sweep-20261024/ISW-163/cfd-final2.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowStdioNodeExecutorTests > tmp/issue-sweep-20261024/ISW-163/stdio-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/stdio-final.log'` | 0 | 14 | 0 | `tmp/issue-sweep-20261024/ISW-163/stdio-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter RuntimeStoreTests > tmp/issue-sweep-20261024/ISW-163/store-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/store-final.log'` | 0 | 28 | 0 | `tmp/issue-sweep-20261024/ISW-163/store-final.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/issue-sweep-20261024/ISW-163/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-20261024/ISW-163/changed-swift-files.nul; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-163/lint-final.log` |

The changed-file SwiftLint manifest is NUL-delimited at
`tmp/issue-sweep-20261024/ISW-163/changed-swift-files.nul` and contains only
the seven Swift files owned by this plan.

### Earlier attempts

- The first build wrapper used zsh's read-only `status` variable after
  `swift build` completed. The wrapper exited 1; its output is preserved in
  `tmp/issue-sweep-20261024/ISW-163/build-wrapper-error.log`. The corrected
  final build above passed.
- An earlier `CommandFailureDiagnosticsTests` compile failed before tests
  because one test call omitted the `command:` label. The failure (exitStatus
  1, testsRun 0, failureCount 0) is preserved in
  `tmp/issue-sweep-20261024/ISW-163/cfd-compile-error.log`; the corrected
  current-source run passed all 7 tests.
- Initial strict lint found a non-failable `Data` to `String` conversion. The
  diagnostic is preserved in `tmp/issue-sweep-20261024/ISW-163/lint-initial.log`;
  the conversion now uses `String(data:encoding:)` with `XCTUnwrap`, and the
  final strict lint run passed.

## Completion criteria

- [x] Policy is opt-in; no-policy process configuration has no capture cap and
      no failure receipt.
- [x] Nonzero command exit emits exactly one non-authoritative event when
      opted in, keeps integer exitCode, and still throws the unchanged provider
      error.
- [x] Restricted schema/path rules, private sibling rejection, 65,536-byte
      allowance and 65,537-byte rejection are covered.
- [x] Failure diagnostics never become accepted output; runtime store retains
      metadata only for the diagnostics event.
- [x] README and the ported implementation plan exist.
- [x] ARM64 build, all three focused suites and strict changed-file SwiftLint
      pass with integer evidence above.

Formal integrity and adversarial review remain downstream workflow steps.

## Adversarial repair: ISW163-ADV-1-utf8-truncation-empty-stdout

Accepted finding: with a diagnostics policy, a 65,537-byte stdout prefix may
end inside a multibyte character. A failable UTF-8 conversion returned an
empty string, allowing exit-zero oversized output to pass the executor's
string-size guard.

The original uncapped decode expression and stderr decode are unchanged. For
capped stdout, the runner decodes valid UTF-8 with the same failable
conversion. If the retained bytes are invalid UTF-8, it returns only U+FFFD
replacement sentinels sized to the retained byte count. The executor's
existing overflow check therefore rejects exit-zero output; the failure
diagnostics parser rejects the sentinel on nonzero exit and emits no
diagnostics. A direct `String(decoding:as:)` implementation was tested but
strict SwiftLint flags that initializer under `optional_data_string_conversion`
(exitStatus 2; `lint-r1.log` and `lint-r1-retry.log`). The replacement sentinel
preserves the intended rejection behavior without suppressing the rule or
changing uncapped decoding.

The real-process regression emits one JSON line containing more than 65,536
bytes of Japanese text. It verifies exit 0 throws exactly
`command stdout exceeded diagnostic capture limit` and exit 7 records one
`rejected` receipt with no diagnostics.

### Repair edit hashes

| File | Pre-edit SHA-256 | Post-edit SHA-256 | Intent evidence |
| --- | --- | --- | --- |
| `Sources/RielaAdapters/LocalProcess.swift` | `LocalProcess.pre-adv1.sha256` | `LocalProcess.post-adv1.sha256` | `LocalProcess.adv1-intent.md` |
| `Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift` | `CommandFailureDiagnosticsTests.pre-adv1.sha256` | `CommandFailureDiagnosticsTests.post-adv1.sha256` | `CommandFailureDiagnosticsTests.adv1-intent.md` |
| `Sources/RielaAdapters/LocalProcess.swift` lint adjustment | `LocalProcess.pre-lint-fix-r1.sha256`, then `LocalProcess.pre-lossy-fallback-r1.sha256` | `LocalProcess.post-lint-fix-r1.sha256`, then `LocalProcess.post-lossy-fallback-r1.sha256` | `LocalProcess.lint-fix-r1-intent.md`, `LocalProcess.lossy-fallback-r1-intent.md` |
| `impl-plans/command-failure-metadata.md` | `command-failure-metadata.pre-adv1-update.sha256` | recorded after this append | `command-failure-metadata.adv1-update-intent.md` |
| This progress record | `progress.pre-adv1-update.sha256` | recorded after this append | `progress.adv1-update-intent.md` |

### Final verification after the repair

Each command ran through ARM64 zsh from the repository root. Logs are complete
and end with integer `exitStatus` values.

| Exact command | exitStatus | testsRun | failureCount | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-20261024/ISW-163/build-r1-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/build-r1-final.log'` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-163/build-r1-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter CommandFailureDiagnosticsTests > tmp/issue-sweep-20261024/ISW-163/cfd-r1-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/cfd-r1-final.log'` | 0 | 8 | 0 | `tmp/issue-sweep-20261024/ISW-163/cfd-r1-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowStdioNodeExecutorTests > tmp/issue-sweep-20261024/ISW-163/stdio-r1-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/stdio-r1-final.log'` | 0 | 14 | 0 | `tmp/issue-sweep-20261024/ISW-163/stdio-r1-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter LocalProcess > tmp/issue-sweep-20261024/ISW-163/localprocess-r1-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/localprocess-r1-final.log'` | 0 | 12 | 0 | `tmp/issue-sweep-20261024/ISW-163/localprocess-r1-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter RuntimeStoreTests > tmp/issue-sweep-20261024/ISW-163/store-r1-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/store-r1-final.log'` | 0 | 28 | 0 | `tmp/issue-sweep-20261024/ISW-163/store-r1-final.log` |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaAdapters/LocalProcess.swift Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift > tmp/issue-sweep-20261024/ISW-163/lint-r1-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/lint-r1-final.log'` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-163/lint-r1-final.log` |

The exact regression passed on this source: `CommandFailureDiagnosticsTests`
ran 8 tests with zero failures. The other required suites passed 14/0, 12/0
and 28/0; build and strict lint exited 0. Earlier intermediate logs remain
available as `cfd-r1.log`, `build-r1.log`, `stdio-r1.log`,
`localprocess-r1.log`, `store-r1.log`, `lint-r1.log` and
`lint-r1-retry.log`; final-source evidence is the table above.

### Numeric SHA-256 edit audit for ISW163-ADV-1

| Edit | File | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- | --- |
| UTF-8 repair implementation | `Sources/RielaAdapters/LocalProcess.swift` | `7223f1bf8d22bd1868c9c1ba2229a3274734e6b52f0b54752a2f30a5b81e86f7` | `3923fb2a7fd2591947119d93f290bdc1d70f615d9bcf154e4f02e1e2c34f72c7` |
| Strict-lint adjustment | `Sources/RielaAdapters/LocalProcess.swift` | `3923fb2a7fd2591947119d93f290bdc1d70f615d9bcf154e4f02e1e2c34f72c7` | `49745435730cee72aee42e0f1d628471fa274d6f0d9a9d3081e59727f6eb9851` |
| Lossy invalid-UTF8 fallback refinement | `Sources/RielaAdapters/LocalProcess.swift` | `49745435730cee72aee42e0f1d628471fa274d6f0d9a9d3081e59727f6eb9851` | `f567e3361f25f23badca90565ddc15ce20476f23dfb588db2875e584304abcba` |
| Real-process regression test | `Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift` | `61aab70a80575050287f23f0823406cab508664f229c502151a9f51106014eaa` | `9cee797650507142849723ee64f7cf40661804987ce56cc36318e6bd6d905c2c` |
| Verification documentation | `impl-plans/command-failure-metadata.md` | `e9f37914c9525101ff43c456ad58d0af443e5ebb0156b45a70d57bd8a86ec5c5` | `b345e55dc3faaeda1c14c33f63a41455d02cc26e1d6e2d582358ecc692a109d2` |
| This progress log append | `impl-plans/progress/issue-sweep-20261024-163-command-failure-diagnostics.md` | `07f247d785fc0364c9be9190a1ca8c381c817fe87659f97cf50378c766ef8460` | Post-append hash is recorded in `tmp/issue-sweep-20261024/ISW-163/progress-post-hash.sha256` to avoid a self-referential hash entry. |

The final LocalProcess and regression-test hashes above match the files verified by the final ARM64 logs in the preceding section.
