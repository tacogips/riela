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
      "promptTemplate": "implement",
      "variables": {}
    }
    """.write(to: nodesDirectory.appendingPathComponent("implement.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "review",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
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

    let text = await app.run([
      "workflow", "inspect", "loop-summary",
      "--workflow-definition-dir", root.path,
      "--output", "text"
    ])
    XCTAssertEqual(text.exitCode, .success)
    XCTAssertTrue(text.stdout.contains("loop: required=true kind=design-implement-review gates=1 stepMetadata=2 artifactRootPolicy=runtime-owned"))
  }

  func testRunAcceptsTemporaryWorkflowJSONFileTarget() async throws {
    let root = repositoryRoot()
    let app = RielaCLIApplication()
    let result = await app.run([
      "workflow", "run", "\(root)/examples/temporary-workflow/temp-workflow.json",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
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
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.status, .completed)
    XCTAssertEqual(run.session.executions.first?.adapterOutput?.provider, "codex-agent")
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("exec --json"), true)
  }

  func testRunHonorsArtifactRootAndForwardsMaxConcurrency() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-run-artifact-root-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let artifactRoot = tempDir.appendingPathComponent("artifacts", isDirectory: true)

    let result = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--artifact-root", artifactRoot.path,
      "--max-concurrency", "2",
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
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore)
    )
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
    XCTAssertEqual(validateFailure.error, "Swift TASK-007 supports local workflow validate only")

    let inspect = await app.run([
      "workflow", "inspect", "worker-only-single-step",
      "--from-registry"
    ])
    XCTAssertEqual(inspect.exitCode, .usage)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.error, "Swift TASK-007 supports local workflow inspect only")
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
      "--max-concurrency", "3",
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
    XCTAssertEqual(request.maxConcurrency, 3)
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
      "--max-concurrency", "3",
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
    XCTAssertEqual((input["maxConcurrency"] as? NSNumber)?.intValue, 3)

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

  func testScopedWorkflowNamesRejectTraversalAndSlashTargets() async throws {
    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "../../examples/worker-only-single-step",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .usage)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertEqual(validateFailure.workflowId, "../../examples/worker-only-single-step")
    XCTAssertEqual(validateFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(validateFailure.error.contains("invalid scoped workflow or package name"))

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "nested/workflow",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .usage)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.workflowId, "nested/workflow")
    XCTAssertEqual(inspectFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(inspectFailure.error.contains("invalid scoped workflow or package name"))

    let run = await RielaCLIApplication().run([
      "workflow", "run", "../worker-only-single-step",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .usage)
    XCTAssertTrue(run.stderr.isEmpty)
    let runFailure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(runFailure.target, "../worker-only-single-step")
    XCTAssertEqual(runFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(runFailure.error.contains("invalid scoped workflow or package name"))
  }

  func testWorkflowResolutionSkipsNonWorkflowPackages() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-non-workflow-package-\(UUID().uuidString)", isDirectory: true)
    let packageDirectory = tempDir
      .appendingPathComponent(".riela/packages/addon-only", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try """
    {
      "name": "addon-only",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Addon-only package",
      "tags": [],
      "registry": "local",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "addons": [{
        "name": "demo-addon",
        "version": "1.0.0",
        "sourcePath": "addons/demo-addon",
        "contentDigest": "sha256:\(String(repeating: "a", count: 64))",
        "capabilities": [{"name": "process.spawn", "reason": "runs package command"}],
        "execution": {"kind": "local-command", "entrypoint": "run.sh"}
      }]
    }
    """.write(to: packageDirectory.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "addon-only",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertEqual(failure.workflowId, "addon-only")
    XCTAssertTrue(failure.error.contains("not found"), failure.error)
    XCTAssertFalse(failure.error.contains("package source validation failed"), failure.error)
  }

  func testScopedWorkflowResolutionRejectsSymlinkEscapes() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-symlink-escape-\(UUID().uuidString)", isDirectory: true)
    let scopedRoot = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
    try FileManager.default.createDirectory(at: scopedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createSymbolicLink(
      at: scopedRoot.appendingPathComponent("escape"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step").standardizedFileURL
    )

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertFalse(validateFailure.valid)
    XCTAssertEqual(validateFailure.workflowId, "escape")
    XCTAssertTrue(validateFailure.error.contains("escapes"))

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .failure)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.workflowId, "escape")
    XCTAssertTrue(inspectFailure.error.contains("escapes"))

    let run = await RielaCLIApplication().run([
      "workflow", "run", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let runFailure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(runFailure.target, "escape")
    XCTAssertTrue(runFailure.error.contains("escapes"))
  }

  func testScopedWorkflowResolutionRejectsSymlinkedWorkflowJSON() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-workflow-json-symlink-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
      .appendingPathComponent("escape", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createSymbolicLink(
      at: workflowDir.appendingPathComponent("workflow.json"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json").standardizedFileURL
    )

    try await assertScopedProjectWorkflowEscapeRejected(workingDirectory: tempDir)
  }

  func testScopedWorkflowResolutionRejectsSymlinkedNodePayload() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-node-payload-symlink-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
      .appendingPathComponent("escape", isDirectory: true)
    let nodesDir = workflowDir.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let workflowJSON = try String(
      contentsOfFile: "\(root)/examples/worker-only-single-step/workflow.json",
      encoding: .utf8
    )
    try workflowJSON.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: nodesDir.appendingPathComponent("node-main-worker.json"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes/node-main-worker.json").standardizedFileURL
    )

    try await assertScopedProjectWorkflowEscapeRejected(workingDirectory: tempDir)
  }

}
