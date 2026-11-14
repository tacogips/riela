# sdwd-03 implementation progress

Dependency sdwd-02 is accepted by dispatch; plan and design §4.1 align. Wired explicit file-backed source sync for lookupOrSeed, retained lookupOnly and configured-launch guards, propagated warnings to stderr and terminal snapshots, and documented drift behavior. No existing test expectations changed.

## IR-SDWD03-TEST-GATE resolution

Integration review authorized runtime scratch from existing tests under the gitignored tmp directory; the earlier ownership objection is withdrawn. Added WorkflowDefinitionSourceDriftResolutionTests with ordinary and configured auto-sync, invalid source, updatePrompt drift and persisted warnings; stored-head 409 and first seed; prepared resolver isolation and lookupOnly; callee auto-sync and one-time zero rows. Runtime and authored timeout, auto-sync audit, repeat behavior and unchanged definition row counts are asserted. The existing WorkflowDefinitionServiceResolutionTests passed unchanged (7 tests, 0 failures); no expectation changes were needed.

Final source hashes are in tmp/stale-definition/sdwd-03-service-resolution-integration/source-hashes-final5.txt, rechecked after the gates. With the Xcode toolchain in an arm64 shell, `swift build` exited 0; isolated HOME and RIELA_WORKFLOW_HOME `swift test --filter "WorkflowDefinitionSourceDriftResolutionTests|WorkflowDefinitionServiceResolutionTests|WorkflowDefinitionSourceDriftTests|InstanceReloadSupportTests|EventLiveServe"` exited 0 (86 tests, 0 failures); and `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache` using changed-swift-round2.nul exited 0. Complete logs and exits are build-final5, test-final5 and lint-final5 under the evidence root, also copied to build, test and lint canonical names. Superseded test-final2 and test-final4 failures were caused by uninitialized fixture stores; both fixtures were corrected and the aggregate rerun. Per-edit snapshots and intentions are in intent-round2-*.txt. Formal review, integration, commit and push remain downstream.

Acceptance: the integration cases and behavioral verification pass; configured route uses lookupOnly and source drift documentation exists.
