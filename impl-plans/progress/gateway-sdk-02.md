# Gateway SDK plan 02 progress

- Status: implementation complete; formal independent review pending.
- Workflow mode: issue-resolution.
- Issue: `docs/briefs/gateway-sdk-addons-2026-09-04.md`.
- Plan: `impl-plans/active/gateway-sdk-addons-02-core-validation.md`.
- Codex-agent reference: none; native Riela Step 6 implementation branch.
- Dependency admission: gateway-sdk-01 in runtime acceptedPlanIds.
- Scope: SDK-free optional catalog projection, defaulted validator context, affected add-on mode/schema validation, and Core tests.
- Completion criteria: all assigned source and tests implemented; focused behavioral gate passed 17 tests, 0 failures. Linux execution remains a final-verification platform gate.

## Changed paths and SHA-256
- `Sources/RielaCore/WorkflowValidation.swift`: pre `7ced1df0910cff5a8481bb839c82afeaf9b8e909e47008b2286fe5427d3d363c`; post `033e0b4cadbe0281bf419d4ff135e2a743d2b2dacb46b4e7a3e556f42d62bfc7`; intent `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-1/intent-0.json`.
- `Sources/RielaCore/WorkflowNodeValidation.swift`: pre `7002189581b0d9a0d6cd31e44d348995a2c0f13bbb3aa20aa998c715a26960c5`; post `9a42cfba2f08401c6fa1b88e43da887e8ff6c4b71007b2f23a7083dae6af36f2`; intent `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-1/intent-1.json`.
- `Sources/RielaCore/WorkflowGatewayAddonValidation.swift`: pre `ABSENT`; post `cb3d3cc703abc74bf0f7fb6e7b5b0dbf7f97f3fc17a467737180116a5da381cc`; intent `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-1/intent-2.json`.
- `Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift`: pre `ABSENT`; post `282796e6891a43c5cf04a2e295e11d6a8749776173b1a784b501419d4ac8bb01`; intent `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-1/intent-3.json`.

## Verification
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowGatewayValidationTests|WorkflowValidation'`: exit 0; 17 passed, 0 failed; complete log `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-1/focused-test-final3.log`; terminal status `focused-test-final3.exit`.
- `xargs -0 swiftlint lint --strict --quiet --no-cache < changed-swift.nul` (nonempty exact-file manifest): exit 0; complete log `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-1/swiftlint-final3.log`; terminal status `swiftlint-final3.exit`.
- `git diff --check`: exit 0; complete log `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-1/diff-check-final3.log`; terminal status `diff-check-final3.exit`.
- Source identity: `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-1/final-source-hashes.json`.

## Findings and remaining work
- Self-check corrected Documents argsTemplate to object shape, Apple queryFile/variablesFile precedence, and literal operation names, then reran all final-source gates.
- No unresolved high/mid finding in assigned scope. Formal test-integrity/adversarial/integration review and Linux final gate remain downstream.

## Adversarial review repair, attempt 2
- Review decision `comm-000042`: rejected with one mid finding. Apple GraphQL passthrough validation rejected object-valued `variables` although the existing runner accepts and JSON-encodes them. Test-integrity review accepted the prior 17-test gate; its coverage missed this case.
- Repair: `Sources/RielaCore/WorkflowGatewayAddonValidation.swift` accepts an object for effective passthrough `variables` while retaining string checks for query and file paths. `Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift` covers object variables in config and inputs, plus an unsupported integer. Original behavior and hunk intent are preserved in `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-2/intent-0.json` and `intent-1.json`.
- Repaired source SHA-256: `Sources/RielaCore/WorkflowGatewayAddonValidation.swift` `0c11705d94d74d5aa9b8d8d87f4d4b560a268de1ab3ea3bdef4bfc2284d90a83`; `Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift` `30744c6eecab2b88dd33743ba073eda09108dee7c91dd641b8c81f8d505348b4`. Complete four-file identity: `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-2/final-source-hashes.json`.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowGatewayValidationTests|WorkflowValidation'`: exit 0, 17 tests, 0 failures. Complete log `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-2/focused-test.log`; terminal status `focused-test.exit`.
- `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-2/changed-swift.nul`: exit 0. Complete log `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-2/swiftlint.log`; terminal status `swiftlint.exit`.
- `git diff --check`: exit 0. Complete log `tmp/gateway-sdk-addons-20260927-comm000008/gateway-sdk-02/attempt-2/diff-check.log`; terminal status `diff-check.exit`.
- Assigned implementation criteria complete on the repaired source; renewed independent adversarial review is pending. Linux and combined-tree checks belong to downstream final verification.
