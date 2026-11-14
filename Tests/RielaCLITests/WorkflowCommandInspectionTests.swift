import Foundation
import RielaAdapters
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testInspectReportsCallableInputAndOutputContracts() async throws {
    let root = repositoryRoot()
    let result = await RielaCLIApplication().run([
      "workflow", "inspect", "codex-design-and-implement-review-loop",
      "--scope", "project",
      "--working-dir", root,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: result.stdout)
    XCTAssertEqual(summary.callable.stepId, "riela-manager")
    XCTAssertEqual(summary.callable.role, .manager)
    XCTAssertEqual(
      summary.callable.input?.description,
      """
      Provide either issue reference details for full issue resolution or Codex-reference planning details for a \
      design-plan-only run. Preferred fields are executionMode, issueUrl, issueNumber, issueRepository, issueTitle, \
      issueBody, targetFeatureArea, requestedBehavior, codexAgentReferences, referenceRepositoryRoot, and \
      referenceRepositoryUrl.
      """
    )
    XCTAssertEqual(
      summary.callable.output?.description,
      """
      Return either the final accepted issue-resolution summary or the accepted design-and-implementation-plan handoff, \
      including any required documentation refresh, the final commit-message, and commit/push status, depending on the \
      requested workflow mode.
      """
    )
  }

  func testResolverHydratesPromptTemplateFilesForTopLevelAndVariantPayloads() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-tests-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("template-workflow", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: workflowDirectory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflowDirectory.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try """
    {
      "workflowId": "template-workflow",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "worker",
      "nodes": [{ "id": "worker", "nodeFile": "nodes/node-worker.json" }],
      "steps": [{ "id": "worker", "nodeId": "worker", "role": "worker", "promptVariant": "review" }]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "worker",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "modelFreeze": false,
      "systemPromptTemplateFile": "prompts/system.md",
      "promptTemplateFile": "prompts/main.md",
      "sessionStartPromptTemplateFile": "prompts/start.md",
      "promptVariants": {
        "review": { "promptTemplateFile": "prompts/review.md" }
      },
      "variables": {}
    }
    """.write(to: workflowDirectory.appendingPathComponent("nodes/node-worker.json"), atomically: true, encoding: .utf8)
    try "system".write(to: workflowDirectory.appendingPathComponent("prompts/system.md"), atomically: true, encoding: .utf8)
    try "main".write(to: workflowDirectory.appendingPathComponent("prompts/main.md"), atomically: true, encoding: .utf8)
    try "start".write(to: workflowDirectory.appendingPathComponent("prompts/start.md"), atomically: true, encoding: .utf8)
    try "review".write(to: workflowDirectory.appendingPathComponent("prompts/review.md"), atomically: true, encoding: .utf8)

    let bundle = try FileSystemWorkflowBundleResolver().resolve(
      WorkflowResolutionOptions(workflowName: "template-workflow", scope: .direct, workflowDefinitionDir: root.path)
    )
    let payload = try XCTUnwrap(bundle.nodePayloads["worker"])

    XCTAssertEqual(payload.systemPromptTemplate, "system")
    XCTAssertEqual(payload.promptTemplate, "main")
    XCTAssertEqual(payload.sessionStartPromptTemplate, "start")
    XCTAssertEqual(payload.promptVariants?["review"]?.promptTemplate, "review")
    XCTAssertEqual(payload.promptTemplateFile, "prompts/main.md")
    XCTAssertEqual(payload.promptVariants?["review"]?.promptTemplateFile, "prompts/review.md")
  }

  func testWorkflowInspectAndUsageExposeLoopMetadataSummary() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-loop-summary-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("loop-summary", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "loop-summary",
      "description": "Loop summary workflow",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "implement",
      "loop": {
        "kind": "design-implement-review",
        "required": true,
        "description": "Implementation loop",
        "evidence": {
          "required": true,
          "artifactRootPolicy": "runtime-owned",
          "requiredSections": ["changed-files", "verification"]
        },
        "policies": {
          "mutation": {
            "allowedWriteRoots": ["Sources", "Tests"],
            "scratchRoot": "tmp/loop-summary",
            "commit": "deny",
            "push": "deny"
          },
          "process": {
            "nestedRiela": "deny",
            "nestedCodex": "deny",
            "allowedBackends": ["codex-agent"],
            "requiredWorkerModel": "gpt-5.5"
          },
          "network": { "mode": "inherit-command" }
        },
        "implementationPlan": {
          "required": true,
          "pathPattern": "impl-plans/active/*.md"
        },
        "gates": [{
          "id": "review-gate",
          "stepId": "review",
          "required": true,
          "acceptWhen": {
            "decision": "accepted",
            "maxHighFindings": 0,
            "maxMediumFindings": 0
          }
        }]
      },
      "nodes": [
        { "id": "implement", "nodeFile": "nodes/implement.json" },
        { "id": "review", "nodeFile": "nodes/review.json" }
      ],
      "steps": [
        {
          "id": "implement",
          "nodeId": "implement",
          "role": "worker",
          "loop": {
            "role": "worker",
            "evidenceTags": ["changed-files"],
            "recordsChangedFiles": true
          },
          "transitions": [{ "toStepId": "review" }]
        },
        {
          "id": "review",
          "nodeId": "review",
          "role": "worker",
          "loop": {
            "role": "gate",
            "gateId": "review-gate",
            "evidenceTags": ["verification"],
            "recordsVerification": true
          }
        }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "implement",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "modelFreeze": false,
      "promptTemplate": "implement",
      "variables": {}
    }
    """.write(to: nodesDirectory.appendingPathComponent("implement.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "review",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "modelFreeze": false,
      "promptTemplate": "review",
      "variables": {}
    }
    """.write(to: nodesDirectory.appendingPathComponent("review.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let inspect = await app.run([
      "workflow", "inspect", "loop-summary",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let inspectSummary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertEqual(inspectSummary.defaultMaxSteps, 5)
    let inspectLoop = try XCTUnwrap(inspectSummary.loop)
    XCTAssertEqual(inspectLoop.kind, "design-implement-review")
    XCTAssertTrue(inspectLoop.required)
    XCTAssertTrue(inspectLoop.evidenceRequired)
    XCTAssertEqual(inspectLoop.artifactRootPolicy, "runtime-owned")
    XCTAssertEqual(inspectLoop.requiredEvidenceSections, ["changed-files", "verification"])
    XCTAssertEqual(inspectLoop.gates, [
      WorkflowLoopGateInspection(
        id: "review-gate",
        stepId: "review",
        required: true,
        acceptDecision: .accepted,
        maxHighFindings: 0,
        maxMediumFindings: 0
      )
    ])
    XCTAssertEqual(inspectLoop.steps.map(\.stepId), ["implement", "review"])
    XCTAssertEqual(inspectLoop.steps.last?.gateId, "review-gate")
    XCTAssertEqual(inspectLoop.policies?.allowedWriteRoots, ["Sources", "Tests"])
    XCTAssertEqual(inspectLoop.policies?.scratchRoot, "tmp/loop-summary")
    XCTAssertEqual(inspectLoop.policies?.commit, "deny")
    XCTAssertEqual(inspectLoop.policies?.push, "deny")
    XCTAssertEqual(inspectLoop.policies?.nestedRiela, "deny")
    XCTAssertEqual(inspectLoop.policies?.nestedCodex, "deny")
    XCTAssertEqual(inspectLoop.policies?.allowedBackends, ["codex-agent"])
    XCTAssertEqual(inspectLoop.policies?.requiredWorkerModel, "gpt-5.5")
    XCTAssertEqual(inspectLoop.policies?.networkMode, "inherit-command")
    XCTAssertEqual(inspectLoop.implementationPlan?.pathPattern, "impl-plans/active/*.md")

    let usage = await app.run([
      "workflow", "usage", "loop-summary",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(usage.exitCode, .success)
    let usageSummary = try decodeJSON(WorkflowInspectionSummary.self, from: usage.stdout)
    XCTAssertEqual(usageSummary.loop, inspectSummary.loop)
    XCTAssertEqual(usageSummary.defaultMaxSteps, 5)

    let text = await app.run([
      "workflow", "inspect", "loop-summary",
      "--workflow-definition-dir", root.path,
      "--output", "text"
    ])
    XCTAssertEqual(text.exitCode, .success)
    XCTAssertTrue(text.stdout.contains("defaultMaxSteps: 5"))
    XCTAssertTrue(text.stdout.contains("loop: required=true kind=design-implement-review gates=1 stepMetadata=2 artifactRootPolicy=runtime-owned"))
  }

  func testRunAcceptsTemporaryWorkflowJSONFileTarget() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-temp-workflow-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let app = RielaCLIApplication()
    let result = await app.run([
      "workflow", "run", "\(root)/examples/temporary-workflow/temp-workflow.json",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.workflowId, "temporary-embedded-status")
    XCTAssertEqual(run.status, .completed)
    XCTAssertEqual(run.nodeExecutions, 1)
  }

  func testWorkflowRunDispatchesCodexAgentBackendToProductionAdapter() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-codex-dispatch-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("codex-dispatch", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let sessionStore = root.appendingPathComponent("sessions", isDirectory: true)
    try """
    {
      "workflowId": "codex-dispatch",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "worker",
      "nodes": [{ "id": "worker", "nodeFile": "nodes/worker.json" }],
      "steps": [{ "id": "worker", "nodeId": "worker", "role": "worker" }]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "worker",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "modelFreeze": false,
      "promptTemplate": "dispatch through codex",
      "variables": {}
    }
    """.write(to: nodesDirectory.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)

    let marker = root.appendingPathComponent("fake-codex-called.txt")
    let fakeCodex = try createExecutable(
      directory: root,
      name: "fake-codex.sh",
      body: """
      if [ "$1" = "login" ] && [ "$2" = "status" ]; then
        exit 0
      fi
      printf '%s\\n' "$*" >> '\(marker.path)'
      printf '{"type":"assistant.snapshot","content":"fake codex reached"}\\n'
      exit 0
      """
    )
    let previousCodexExecutable = environmentValue("RIELA_CODEX_AGENT_EXECUTABLE")
    setEnvironmentValue("RIELA_CODEX_AGENT_EXECUTABLE", fakeCodex.path)
    defer { setEnvironmentValue("RIELA_CODEX_AGENT_EXECUTABLE", previousCodexExecutable) }

    let result = await RielaCLIApplication().run([
      "workflow", "run", "codex-dispatch",
      "--workflow-definition-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.status, .completed)
    XCTAssertEqual(run.session.executions.first?.adapterOutput?.provider, "codex-agent")
    let recordedInvocations = try String(contentsOf: marker, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    XCTAssertTrue(recordedInvocations.contains { $0.hasPrefix("exec --json") })
  }

  func testProjectScopeCodexDesignIntakePromptIncludesWorkflowRunVariables() async throws {
    let repositoryRoot = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-codex-intake-variables-\(UUID().uuidString)", isDirectory: true)
    let promptDirectory = tempDir.appendingPathComponent("prompts", isDirectory: true)
    try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let counter = tempDir.appendingPathComponent("prompt-count.txt")
    let fakeCodex = try createExecutable(
      directory: tempDir,
      name: "fake-codex.sh",
      body: """
      if [ "$1" = "login" ] && [ "$2" = "status" ]; then
        exit 0
      fi
      count=0
      if [ -f '\(counter.path)' ]; then
        count=$(cat '\(counter.path)')
      fi
      count=$((count + 1))
      printf '%s' "$count" > '\(counter.path)'
      cat > '\(promptDirectory.path)'/prompt-"$count".txt
      if [ "$count" = "1" ]; then
        cat <<'JSON'
      {
        "completionPassed": true,
        "when": { "always": true },
        "payload": { "status": "manager-ready" }
      }
      JSON
      else
        cat <<'JSON'
      {
        "completionPassed": true,
        "when": { "has_feature_fanout": false },
        "payload": {
          "workflowMode": "issue-resolution",
          "problemSummary": "captured intake",
          "acceptanceSignals": [],
          "impactedAreas": [],
          "constraints": [],
          "unknowns": [],
          "risks": [],
          "requiresAdversarialReview": false,
          "codexAgentReferences": [],
          "featureFanoutItems": []
        }
      }
      JSON
      fi
      exit 0
      """
    )
    let previousCodexExecutable = environmentValue("RIELA_CODEX_AGENT_EXECUTABLE")
    setEnvironmentValue("RIELA_CODEX_AGENT_EXECUTABLE", fakeCodex.path)
    defer { setEnvironmentValue("RIELA_CODEX_AGENT_EXECUTABLE", previousCodexExecutable) }

    let variableObject: JSONObject = [
      "workflowInput": .object([
        "executionMode": .string("review-and-improve-existing-work"),
        "targetFeatureArea": .string("RielaApp Instances window performance"),
        "requestedBehavior": .string("Review project input visibility"),
        "codexAgentReferences": .array([.string("Sources/RielaApp/EntryPoint.swift")]),
        "referenceRepositoryRoot": .string(repositoryRoot)
      ]),
      "workflowCall": .object([
        "input": .object([
          "workflowInput": .object([
            "requestedBehavior": .string("Prefer cross workflow input")
          ])
        ])
      ])
    ]
    let variables = try jsonString(variableObject)

    let result = await RielaCLIApplication().run([
      "workflow", "run", "codex-design-and-implement-review-loop",
      "--scope", "project",
      "--working-dir", repositoryRoot,
      "--artifact-root", tempDir.appendingPathComponent("artifacts", isDirectory: true).path,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--variables", variables,
      "--max-steps", "2",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, CLIExitCode.failure)
    let intakePrompt = try String(
      contentsOf: promptDirectory.appendingPathComponent("prompt-2.txt"),
      encoding: .utf8
    )
    XCTAssertTrue(intakePrompt.contains("Runtime variables are available under `runtimeVariables`"))
    XCTAssertTrue(intakePrompt.contains(#""requestedBehavior":"Review project input visibility""#))
    XCTAssertTrue(intakePrompt.contains(#""targetFeatureArea":"RielaApp Instances window performance""#))
    XCTAssertTrue(intakePrompt.contains(#""codexAgentReferences":["Sources/RielaApp/EntryPoint.swift"]"#))
    XCTAssertTrue(intakePrompt.contains(#""requestedBehavior":"Prefer cross workflow input""#))
  }

  func testRunHonorsArtifactRoot() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-run-artifact-root-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let artifactRoot = tempDir.appendingPathComponent("artifacts", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)

    let result = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--artifact-root", artifactRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.status, .completed)
    let artifactSnapshot = artifactRoot
      .appendingPathComponent(run.session.sessionId, isDirectory: true)
      .appendingPathComponent("runtime-snapshot.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifactSnapshot.path))
  }

  func testSessionRerunUsesPersistedSessionStore() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-session-rerun-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true).path
    let app = RielaCLIApplication()

    let firstRun = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore,
      "--output", "json"
    ])
    XCTAssertEqual(firstRun.exitCode, .success, firstRun.stderr)
    let first = try decodeJSON(WorkflowRunResult.self, from: firstRun.stdout)
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore)
    )
    var firstSnapshot = try runtimeStore.load(sessionId: first.session.sessionId)
    let loopEvidenceDate = first.session.updatedAt
    firstSnapshot.loopEvidence = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-\(first.session.sessionId)",
      workflowId: first.session.workflowId,
      sessionId: first.session.sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      gates: [
        LoopGateResult(
          gateId: "implementation-review",
          stepId: "main-worker",
          stepExecutionId: "main-worker-exec",
          decision: .accepted
        )
      ],
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: loopEvidenceDate,
      updatedAt: loopEvidenceDate
    )
    try runtimeStore.save(firstSnapshot)

    let loopList = await app.run([
      "loop", "list",
      "--workflow", "worker-only-single-step",
      "--gate-decision", "accepted",
      "--session-store", sessionStore,
      "--output", "json"
    ])
    XCTAssertEqual(loopList.exitCode, .success, loopList.stderr)
    let listPayload = try decodeJSON(LoopSessionOverviewCommandResult.self, from: loopList.stdout)
    XCTAssertEqual(listPayload.sessions.map(\.sessionId), [first.session.sessionId])
    XCTAssertEqual(listPayload.sessions.first?.lastGateDecision, "accepted")

    let loopListJSONL = await app.run([
      "loop", "list",
      "--workflow", "worker-only-single-step",
      "--gate-decision", "accepted",
      "--session-store", sessionStore,
      "--output", "jsonl"
    ])
    XCTAssertEqual(loopListJSONL.exitCode, .success, loopListJSONL.stderr)
    let jsonlLines = loopListJSONL.stdout.split(separator: "\n")
    XCTAssertEqual(jsonlLines.count, 1, loopListJSONL.stdout)
    let jsonlOverview = try decodeJSON(LoopSessionOverview.self, from: String(jsonlLines[0]))
    XCTAssertEqual(jsonlOverview.sessionId, first.session.sessionId)

    let loopHistory = await app.run([
      "loop", "history", "worker-only-single-step",
      "--session-store", sessionStore,
      "--output", "table"
    ])
    XCTAssertEqual(loopHistory.exitCode, .success, loopHistory.stderr)
    XCTAssertTrue(loopHistory.stdout.contains(first.session.sessionId), loopHistory.stdout)

    let rerun = await app.run([
      "session", "rerun", first.session.sessionId, "main-worker",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr)
    let payload = try decodeJSON(SessionRerunCommandResult.self, from: rerun.stdout)
    XCTAssertEqual(payload.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(payload.rerunFromStepId, "main-worker")
    XCTAssertNotEqual(payload.sessionId, first.session.sessionId)
    XCTAssertEqual(payload.status, .completed)
    XCTAssertEqual(payload.recovery?.entryMode, .rerun)
    XCTAssertEqual(payload.recovery?.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(payload.recovery?.sourceStepId, "main-worker")
    let loopRecover = await app.run([
      "loop", "recover", first.session.sessionId,
      "--from-step", "main-worker",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore,
      "--output", "json"
    ])
    XCTAssertEqual(loopRecover.exitCode, .success, loopRecover.stderr)
    let secondPayload = try decodeJSON(SessionRerunCommandResult.self, from: loopRecover.stdout)
    XCTAssertEqual(secondPayload.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(secondPayload.rerunFromStepId, "main-worker")
    XCTAssertNotEqual(secondPayload.sessionId, payload.sessionId)
    XCTAssertEqual(secondPayload.recovery?.entryMode, .rerun)
    let loopRecoverFromGate = await app.run([
      "loop", "recover", first.session.sessionId,
      "--from-gate", "implementation-review",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore,
      "--output", "json"
    ])
    XCTAssertEqual(loopRecoverFromGate.exitCode, .success, loopRecoverFromGate.stderr)
    let gatePayload = try decodeJSON(SessionRerunCommandResult.self, from: loopRecoverFromGate.stdout)
    XCTAssertEqual(gatePayload.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(gatePayload.rerunFromStepId, "main-worker")
    XCTAssertEqual(gatePayload.recovery?.entryMode, .rerun)
    for sessionId in [payload.sessionId, secondPayload.sessionId] {
      XCTAssertEqual(try runtimeStore.load(sessionId: sessionId).session.sessionId, sessionId)
      XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: sessionStore, isDirectory: true)
        .appendingPathComponent("runtime-records", isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
        .appendingPathComponent("runtime-snapshot.json").path))
    }
  }

  func testSessionRerunRejectsNestedSuperviserFlag() async throws {
    let result = await RielaCLIApplication().run([
      "session", "rerun", "sess-1", "step-1", "--nested-superviser"
    ])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(SessionCommandFailureResult.self, from: result.stdout)
    XCTAssertTrue(failure.error.contains("not supported for session rerun"))
  }

  func testUserScopeWorkflowRunSupportsDefaultAutoScopeSessionRerunAndResume() async throws {
    let root = repositoryRoot()
    let layout = try makeIsolatedUserScopeWorkflowLayout(
      repositoryRoot: root,
      workflowName: "worker-only-single-step"
    )
    defer { try? FileManager.default.removeItem(at: layout.base) }

    let mockScenario = "\(root)/examples/worker-only-single-step/mock-scenario.json"
    let app = RielaCLIApplication()
    let environment = ["HOME": layout.homeRoot.path]

    let firstRun = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--scope", "user",
      "--working-dir", layout.projectRoot.path,
      "--mock-scenario", mockScenario,
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(firstRun.exitCode, .success, firstRun.stderr)
    let first = try decodeJSON(WorkflowRunResult.self, from: firstRun.stdout)

    let rerun = await app.run([
      "session", "rerun", first.session.sessionId, "main-worker",
      "--working-dir", layout.projectRoot.path,
      "--mock-scenario", mockScenario,
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr)
    let rerunPayload = try decodeJSON(SessionRerunCommandResult.self, from: rerun.stdout)
    XCTAssertEqual(rerunPayload.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(rerunPayload.rerunFromStepId, "main-worker")
    XCTAssertEqual(rerunPayload.recovery?.entryMode, .rerun)
    XCTAssertEqual(rerunPayload.recovery?.sourceSessionId, first.session.sessionId)

    let resume = await app.run([
      "session", "resume", rerunPayload.sessionId,
      "--working-dir", layout.projectRoot.path,
      "--mock-scenario", mockScenario,
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(resume.exitCode, .success, resume.stderr)
    let resumePayload = try decodeJSON(SessionResumeCommandResult.self, from: resume.stdout)
    XCTAssertEqual(resumePayload.sourceSessionId, rerunPayload.sessionId)
    XCTAssertEqual(resumePayload.sessionId, rerunPayload.sessionId)
    XCTAssertEqual(resumePayload.status, .completed)
    XCTAssertEqual(resumePayload.recovery?.entryMode, .resume)
    XCTAssertEqual(resumePayload.recovery?.sourceSessionId, rerunPayload.sessionId)
  }

  func testValidateAndInspectRejectRemoteResolutionFlagsWithUsageExit() async throws {
    let app = RielaCLIApplication()

    let validate = await app.run([
      "workflow", "validate", "worker-only-single-step",
      "--endpoint", "http://localhost:4000/graphql"
    ])
    XCTAssertEqual(validate.exitCode, .usage)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertEqual(validateFailure.error, "remote workflow validate is not supported by the local CLI runner")

    let inspect = await app.run([
      "workflow", "inspect", "worker-only-single-step",
      "--from-registry"
    ])
    XCTAssertEqual(inspect.exitCode, .usage)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.error, "remote workflow inspect is not supported by the local CLI runner")
  }

  func testRunJSONFailureReturnsParseableFailureEnvelope() async throws {
    let root = repositoryRoot()
    let result = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--variables", #"{"unterminated": true"#,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.target, "worker-only-single-step")
    XCTAssertEqual(failure.status, .failed)
    XCTAssertEqual(failure.exitCode, CLIExitCode.failure.rawValue)
    XCTAssertFalse(failure.error.isEmpty)
  }

  func testWorkflowRunUsesGraphQLEndpointTransport() async throws {
    let previousToken = environmentValue("RIELA_REMOTE_AUTH_TOKEN")
    setEnvironmentValue("RIELA_REMOTE_AUTH_TOKEN", "env-token-1")
    defer { setEnvironmentValue("RIELA_REMOTE_AUTH_TOKEN", previousToken) }

    let transport = RecordingWorkflowGraphQLRunTransport()
    let app = RielaCLIApplication(runCommand: WorkflowRunCommand(graphQLTransport: transport))
    let result = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://localhost:4000/graphql",
      "--auth-token-env", "RIELA_REMOTE_AUTH_TOKEN",
      "--variables", #"{"request":"remote"}"#,
      "--disable-default-loop-guard",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stderr.isEmpty)
    let remote = try decodeJSON(WorkflowRemoteRunResult.self, from: result.stdout)
    XCTAssertEqual(remote.sessionId, "remote-session-1")
    let recordedEndpoint = await transport.recordedEndpoint()
    XCTAssertEqual(recordedEndpoint, "http://localhost:4000/graphql")
    let recordedRequest = await transport.recordedRequest()
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(request.workflowName, "worker-only-single-step")
    XCTAssertEqual(request.runtimeVariables["request"], .string("remote"))
    XCTAssertNil(request.maxConcurrency)
    XCTAssertTrue(request.disableDefaultLoopGuard)
    XCTAssertEqual(request.authToken, "env-token-1")
    XCTAssertEqual(request.authTokenEnv, "RIELA_REMOTE_AUTH_TOKEN")
  }

  func testWorkflowRunEndpointUsesRielaAuthEnvironment() async throws {
    let previousRielaToken = environmentValue("RIELA_MANAGER_AUTH_TOKEN")
    let previousRielaSession = environmentValue("RIELA_MANAGER_SESSION_ID")
    defer {
      setEnvironmentValue("RIELA_MANAGER_AUTH_TOKEN", previousRielaToken)
      setEnvironmentValue("RIELA_MANAGER_SESSION_ID", previousRielaSession)
    }

    setEnvironmentValue("RIELA_MANAGER_AUTH_TOKEN", "riela-token")
    setEnvironmentValue("RIELA_MANAGER_SESSION_ID", "riela-session")

    let primaryTransport = RecordingWorkflowGraphQLRunTransport()
    let primaryApp = RielaCLIApplication(runCommand: WorkflowRunCommand(graphQLTransport: primaryTransport))
    let primaryResult = await primaryApp.run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://localhost:4000/graphql",
      "--output", "json"
    ])

    XCTAssertEqual(primaryResult.exitCode, .success, primaryResult.stderr)
    let recordedPrimaryRequest = await primaryTransport.recordedRequest()
    let primaryRequest = try XCTUnwrap(recordedPrimaryRequest)
    XCTAssertEqual(primaryRequest.authToken, "riela-token")
    XCTAssertEqual(primaryRequest.authTokenEnv, "RIELA_MANAGER_AUTH_TOKEN")
    XCTAssertEqual(primaryRequest.managerSessionId, "riela-session")
  }

  func testURLSessionWorkflowRunUsesSchemaAccurateRemotePayloadAndPausedStatus() async throws {
    RecordingGraphQLURLProtocol.reset(responses: remoteGraphQLRunResponses())
    URLProtocol.registerClass(RecordingGraphQLURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingGraphQLURLProtocol.self) }
    let traceparent = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"

    let result = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://riela.test/graphql",
      "--auth-token", "explicit-token",
      "--variables", #"{"request":"remote"}"#,
      "--disable-default-loop-guard",
      "--timeout-ms", "100",
      "--output", "json"
    ], environment: [
      "RIELA_MANAGER_SESSION_ID": "manager-session-1",
      "traceparent": traceparent,
      "tracestate": "vendor=state",
      "baggage": "tenant=blue"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let remote = try decodeJSON(WorkflowRemoteRunResult.self, from: result.stdout)
    XCTAssertEqual(remote.sessionId, "remote-session-1")
    XCTAssertEqual(remote.status, "paused")
    XCTAssertEqual(remote.workflowName, "remote-workflow")
    XCTAssertEqual(remote.workflowId, "remote-workflow-id")
    XCTAssertEqual(remote.nodeExecutions, 2)
    XCTAssertEqual(remote.transitions, 1)

    let bodies = RecordingGraphQLURLProtocol.bodies()
    XCTAssertEqual(bodies.count, 2)
    let headers = RecordingGraphQLURLProtocol.headers()
    XCTAssertEqual(headers.count, 2)
    for header in headers {
      XCTAssertEqual(header["Authorization"], "Bearer explicit-token")
      XCTAssertEqual(header["X-Riela-Manager-Session-Id"], "manager-session-1")
      XCTAssertEqual(header["traceparent"], traceparent)
      XCTAssertEqual(header["tracestate"], "vendor=state")
      XCTAssertEqual(header["baggage"], "tenant=blue")
    }
    let executeBody = try XCTUnwrap(bodies.first)
    let executeQuery = try XCTUnwrap(executeBody["query"] as? String)
    XCTAssertTrue(executeQuery.contains("executeWorkflow(input: $input)"))
    XCTAssertFalse(executeQuery.contains("workflowName"))
    XCTAssertFalse(executeQuery.contains("workflowId"))
    XCTAssertFalse(executeQuery.contains("nodeExecutions"))
    XCTAssertFalse(executeQuery.contains("transitions"))
    let variables = try XCTUnwrap(executeBody["variables"] as? [String: Any])
    let input = try XCTUnwrap(variables["input"] as? [String: Any])
    XCTAssertEqual(input["workflowName"] as? String, "worker-only-single-step")
    XCTAssertNil(input["autoImprove"])
    XCTAssertNil(input["autoImprovePolicy"])
    XCTAssertNil(input["timeoutMs"])
    XCTAssertNil(input["authToken"])
    XCTAssertNil(input["authTokenEnv"])
    XCTAssertNil(input["managerSessionId"])
    XCTAssertNil(input["maxConcurrency"])
    XCTAssertEqual(input["disableDefaultLoopGuard"] as? Bool, true)

    let summaryBody = try XCTUnwrap(bodies.last)
    let summaryQuery = try XCTUnwrap(summaryBody["query"] as? String)
    XCTAssertTrue(summaryQuery.contains("workflowExecution(workflowExecutionId: $workflowExecutionId)"))
    let summaryVariables = try XCTUnwrap(summaryBody["variables"] as? [String: Any])
    XCTAssertEqual(summaryVariables["workflowExecutionId"] as? String, "remote-exec-1")
  }

  func testURLSessionWorkflowRunAutoImproveIsOptInOverRemotePayload() async throws {
    URLProtocol.registerClass(RecordingGraphQLURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingGraphQLURLProtocol.self) }

    RecordingGraphQLURLProtocol.reset(responses: remoteGraphQLRunResponses(executionId: "remote-exec-disabled"))
    let disabled = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://riela.test/graphql",
      "--no-auto-improve",
      "--output", "json"
    ])

    XCTAssertEqual(disabled.exitCode, .success, disabled.stderr)
    let disabledBodies = RecordingGraphQLURLProtocol.bodies()
    let disabledExecuteBody = try XCTUnwrap(disabledBodies.first)
    let disabledVariables = try XCTUnwrap(disabledExecuteBody["variables"] as? [String: Any])
    let disabledInput = try XCTUnwrap(disabledVariables["input"] as? [String: Any])
    XCTAssertNil(disabledInput["autoImprove"])
    XCTAssertNil(disabledInput["nestedSuperviser"])

    RecordingGraphQLURLProtocol.reset(responses: remoteGraphQLRunResponses(executionId: "remote-exec-enabled"))
    let enabled = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://riela.test/graphql",
      "--auto-improve",
      "--max-supervised-attempts", "4",
      "--nested-supervisor",
      "--output", "json"
    ])

    XCTAssertEqual(enabled.exitCode, .success, enabled.stderr)
    let enabledBodies = RecordingGraphQLURLProtocol.bodies()
    let enabledExecuteBody = try XCTUnwrap(enabledBodies.first)
    let enabledVariables = try XCTUnwrap(enabledExecuteBody["variables"] as? [String: Any])
    let enabledInput = try XCTUnwrap(enabledVariables["input"] as? [String: Any])
    let enabledAutoImprove = try XCTUnwrap(enabledInput["autoImprove"] as? [String: Any])
    XCTAssertEqual((enabledAutoImprove["enabled"] as? NSNumber)?.boolValue, true)
    XCTAssertEqual((enabledAutoImprove["maxSupervisedAttempts"] as? NSNumber)?.intValue, 4)
    XCTAssertEqual((enabledAutoImprove["stallDetectionEnabled"] as? NSNumber)?.boolValue, false)
    XCTAssertEqual((enabledInput["nestedSuperviser"] as? NSNumber)?.boolValue, true)
  }

  func testParserValidateJSONFailureReturnsParseableEnvelopeForUnknownOption() async throws {
    let result = await RielaCLIApplication().run([
      "workflow", "validate", "worker-only-single-step",
      "--unknown",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: result.stdout)
    XCTAssertFalse(failure.valid)
    XCTAssertEqual(failure.workflowId, "worker-only-single-step")
    XCTAssertEqual(failure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(failure.error.contains("unknown option '--unknown'"))
  }

  func testParserInspectJSONFailureReturnsParseableEnvelopeForMissingOptionValue() async throws {
    let result = await RielaCLIApplication().run([
      "workflow", "inspect", "worker-only-single-step",
      "--workflow-definition-dir",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowInspectionFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.workflowId, "worker-only-single-step")
    XCTAssertEqual(failure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(failure.error.contains("--workflow-definition-dir requires a value"))
  }

}
