# sdwd-02 progress

- Workflow mode: issue-resolution; no dependencies in dispatch. Plan aligns with design §4.1, but its default resolver signature crosses a module boundary.
- Blocked: `FileSystemWorkflowBundleResolver` is declared in `Sources/RielaCLI/WorkflowResolution.swift:31`. `RielaCLI` depends on `RielaWorkflowRegistry` (Package.swift), while registry does not depend on CLI. The required default argument in registry cannot reference this type without a dependency cycle. Resolver extraction requires paths outside this plan's write scope, or the API and downstream callers must be amended to require an explicit resolver.
- Partial work: added drift result, report, outcome, pure classification and diagnostic source. Service integration and required tests remain incomplete. Intent recorded in `tmp/stale-definition/sdwd-02-source-drift-service/intent-01.txt`; service pre-edit hash in `pre-service.sha`. No existing service method was changed.
- Resume after accepted plan/ownership amendment resolves the resolver default and provides the required write paths. Then finish service integration and tests, run the three required arm64 gates, and update acceptance criteria.
- Acceptance criteria: all remain unchecked; no success-shaped verification was run after identifying the blocker.

## Amendment 2026-11-11 (blocked-wave-scope-or-contract, round 1)

The accepted integration repair makes `fileResolver` mandatory on both source-drift methods: the concrete filesystem resolver belongs to RielaCLI and cannot be a registry default. sdwd-03 passes `sourceFileResolver`; sdwd-04 must pass `FileSystemWorkflowBundleResolver()` explicitly. The design and classification remain unchanged.

- [x] Additive service methods, explicit file resolver, canonical digests, validation, expected-head import and conflict reread. Existing service bodies unchanged.
- [x] Drift diagnostics and remediation; strict lint line lengths repaired.
- [x] All planned test scenarios and existing focused suites: 34 tests, zero failures.
- [x] arm64 build, isolated-home focused tests, and exact changed-file strict lint: `build.exit`, `test.exit`, `lint.exit` all 0; complete logs alongside them under `tmp/stale-definition/sdwd-02-source-drift-service/`.
- The first aggregate run was interrupted (130) after sampling showed an existing CLI test waiting in the user workflow registry. The successful rerun sets HOME and RIELA_WORKFLOW_HOME to plan-local directories. Earlier log: `test-attempt1.log`; sample: `test-sample.txt`.
- Final SHA-256: `WorkflowDefinitionSourceDrift.swift` 9eaf525389ce3522671b07245eb99fa07582bd6eb0ac575b88b8aa929b262f1a; `WorkflowDefinitionService.swift` 92defbb06f1f1b174fab92727341fe9fdc9bfb0dec2677cf03791994bdee62bc; `WorkflowDefinitionSourceDriftTests.swift` e8815fc8cc39d3526c0ee5674d6ba40c036f7770c45e7323a28f634a76f1b96f. Pre-edit snapshots and intents are in the evidence root.
- Formal independent review and integration remain downstream.
