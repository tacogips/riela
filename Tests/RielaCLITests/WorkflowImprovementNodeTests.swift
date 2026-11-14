import Foundation
import RielaAdapters
import RielaCore
import RielaSQLite
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class WorkflowImprovementNodeTests: XCTestCase {
  private final class Clock: @unchecked Sendable { var now: Date; init(_ now: Date) { self.now = now } }
  private struct ValidationCase {
    var reason: String
    var patch: JSONValue
    var status: String
    var expectedReason: String?
  }

  private struct DuplicateCase {
    var patch: JSONValue
    var expectedReason: String
    var expectedInvocations: Int
    var label: String
  }

  func testServiceRunsApplyAuditedPromptUpdateAndNextRunUsesIt() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let runner = InProcessRielaCLIRunner()
    let originalFiles = try fileDigests(root: fixture.workflow)
    var command = WorkflowRunCommand()
    command.improvementCLIProcessRunnerOverride = runner
    let first = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
    let seed = try XCTUnwrap(first.session.definitionSource?.versionId)
    XCTAssertEqual(addonPayload(first, stepId: "improve-context")?["reason"], .string("noPreviousRun"))
    XCTAssertEqual(addonPayload(first, stepId: "improve-context")?["status"], .string("ok"))
    XCTAssertFalse(first.session.executions.contains { $0.stepId == "improve-apply" })

    let second = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
    XCTAssertEqual(second.session.definitionSource?.versionId, seed)
    let previousRow = try XCTUnwrap(CLIWorkflowSessionStore(rootDirectory: fixture.store.path)
      .list(workflowName: "definition-store-self-improvement", limit: 100)
      .first { $0.session.sessionId == first.session.sessionId })
    XCTAssertTrue(previousRow.session.executions.isEmpty, "list rows should omit step executions")
    let context = try XCTUnwrap(addonPayload(second, stepId: "improve-context"))
    XCTAssertEqual(context["runDigest"]?.objectValue?["sessionId"], .string(first.session.sessionId))
    let digest = try XCTUnwrap(context["runDigest"]?.objectValue?["stepExecutions"]?.arrayValue)
    let summarizeExecutionId = first.session.executions.first(where: { $0.stepId == "summarize" })?.executionId
    XCTAssertTrue(digest.contains { $0.objectValue?["stepExecutionId"]?.stringValue == summarizeExecutionId }, "digest=\(digest), expected=\(String(describing: summarizeExecutionId))")
    XCTAssertTrue(digest.contains { $0.objectValue?["stepExecutionId"]?.stringValue == "summarize-attempt-1-exec-1" }, "digest=\(digest)")
    XCTAssertFalse(digest.contains { $0.objectValue?["nodeId"]?.stringValue?.hasPrefix("improve-") == true })
    XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["status"], .string("applied"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("tmp/efficient-history").path),
      "self-improve patch files must stay in the OS temporary directory")
    XCTAssertEqual(runner.invocationCount, 1)
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let audits = try store.history(workflowName: "definition-store-self-improvement")
    XCTAssertTrue(audits.allSatisfy(\.retained), "without project config, the default history window retains the current versions")
    XCTAssertEqual(audits.first?.operation, .update)
    XCTAssertEqual(audits.first?.actor.kind, .improvementNode)
    XCTAssertEqual(audits.first?.reason, "summaries omitted the action items; require an action-item list")
    XCTAssertEqual(audits.first?.evidence.first?.kind, .session)
    XCTAssertEqual(audits.first?.evidence.first?.id, first.session.sessionId)

    let third = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
    XCTAssertEqual(third.session.definitionSource?.versionId, audits.first?.versionId)
    let summarize = try XCTUnwrap(third.session.executions.first(where: { $0.stepId == "summarize" }))
    XCTAssertTrue(summarize.inputSnapshot? ["promptText"]?.stringValue?.contains("explicit action-item list") == true)
    XCTAssertEqual(try fileDigests(root: fixture.workflow), originalFiles)
  }

  func testProjectHistoryRetentionConfigAppliesToSelfImprovementWrite() async throws {
    let fixture = try makeFixture(projectWorkflowLayout: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let config = fixture.root.appendingPathComponent(".riela/config.json")
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"workflowDefinitions":{"historyRetention":2}}"#.write(to: config, atomically: true, encoding: .utf8)

    let clock = Clock(Date(timeIntervalSinceNow: -30 * 24 * 60 * 60))
    let service = WorkflowDefinitionService(storeRoot: fixture.store.path, fileResolver: FileSystemWorkflowBundleResolver(),
      defaultHistoryRetention: 10, now: { clock.now })
    let resolution = WorkflowResolutionOptions(workflowName: "definition-store-self-improvement", scope: .project,
      workingDirectory: fixture.root.path)
    _ = try service.importDefinition(resolution: resolution, force: false, reason: nil, evidence: [], actor: WorkflowDefinitionActor(kind: .cli))
    for prompt in ["historical two", "historical three", "historical four"] {
      clock.now = clock.now.addingTimeInterval(25 * 60 * 60)
      _ = try service.updatePrompt(workflowName: "definition-store-self-improvement", nodeId: "summarize",
        field: .node(.promptTemplate), text: prompt, reason: "prepopulate", expectedVersionId: nil,
        evidence: [], actor: WorkflowDefinitionActor(kind: .cli))
    }
    let beforeStore = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let beforeHistory = try beforeStore.history(workflowName: "definition-store-self-improvement", limit: 10)
    let oldestNonFileVersions = Array(beforeHistory.filter { $0.operation == .updatePrompt }.reversed().prefix(2).map(\.versionId))
    XCTAssertEqual(oldestNonFileVersions.count, 2)
    let homeTmp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tmp/efficient-history")
    let cwdTmp = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/efficient-history")
    let homeTmpExisted = FileManager.default.fileExists(atPath: homeTmp.path)
    let cwdTmpExisted = FileManager.default.fileExists(atPath: cwdTmp.path)

    let runner = InProcessRielaCLIRunner()
    var command = WorkflowRunCommand()
    command.improvementCLIProcessRunnerOverride = runner
    let first = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "config-retention")))
    XCTAssertFalse(first.session.executions.contains { $0.stepId == "improve-apply" })
    try writeProposal(reason: "apply configured history", patch: .array([.object([
      "op": .string("replace"), "path": .string("/workflow.json/defaults/nodeTimeoutMs"), "value": .integer(31000)
    ])]), to: fixture.scenario)
    let second = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "config-retention")))
    XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["status"], .string("applied"))
    XCTAssertEqual(runner.invocationCount, 1)
    let afterStore = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    for versionId in oldestNonFileVersions {
      XCTAssertThrowsError(try afterStore.document(versionId: versionId), "expected configured retention to drop \(versionId)")
    }
    XCTAssertEqual(FileManager.default.fileExists(atPath: homeTmp.path), homeTmpExisted,
      "self-improve must not create a temporary directory under HOME")
    XCTAssertEqual(FileManager.default.fileExists(atPath: cwdTmp.path), cwdTmpExisted,
      "self-improve must not create a temporary directory under the current directory")
  }

  func testOneTimeRunSkipsImprovementWithoutStoreOrCLI() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let runner = InProcessRielaCLIRunner()
    var command = WorkflowRunCommand()
    command.improvementCLIProcessRunnerOverride = runner
    let result = try await run(command, fixture: fixture, mode: .oneTime)
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(addonPayload(result, stepId: "improve-context")?["reason"], .string("oneTimeRun"))
    XCTAssertFalse(result.session.executions.contains { $0.stepId == "improve-apply" })
    XCTAssertEqual(runner.invocationCount, 0)
    XCTAssertNil(try WorkflowDefinitionStore(rootDirectory: fixture.store.path).current(workflowName: "definition-store-self-improvement"))
    XCTAssertEqual(try definitionRowCounts(root: fixture.store.path), [0, 0, 0, 0])
  }

  func testApplyOutcomeClassifiesIdempotentConflictByActor() throws {
    let conflict = #"{"accepted":false,"error":{"code":"definition_conflict"}}"#
    let sameActor = #"[{"versionId":"v2","auditId":"a2","afterDigest":"d2","actor":{"id":"actor"}}]"#
    let differentActor = #"[{"versionId":"v2","auditId":"a2","actor":{"id":"other"}}]"#
    XCTAssertEqual(WorkflowImprovementApplyOutcome.classify(updateStdout: conflict, historyStdout: sameActor, expectedActorId: "actor")?.status, .applied)
    XCTAssertEqual(WorkflowImprovementApplyOutcome.classify(updateStdout: conflict, historyStdout: differentActor, expectedActorId: "actor")?.reason, "definition_conflict")
  }

  func testApplyConflictKeepsManualHeadAndRunPin() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let inner = InProcessRielaCLIRunner()
    var seedCommand = WorkflowRunCommand()
    seedCommand.improvementCLIProcessRunnerOverride = inner
    let first = try await run(seedCommand, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
    let seedVersion = try XCTUnwrap(first.session.definitionSource?.versionId)
    let headMovingRunner = HeadMovingCLIRunner(inner: inner, storeRoot: fixture.store.path)
    var competingCommand = WorkflowRunCommand()
    competingCommand.improvementCLIProcessRunnerOverride = headMovingRunner
    let second = try await run(competingCommand, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
    XCTAssertEqual(second.session.definitionSource?.versionId, seedVersion)
    XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["status"], .string("rejected"))
    XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["reason"], .string("definition_conflict"))
    let audits = try WorkflowDefinitionStore(rootDirectory: fixture.store.path).history(workflowName: "definition-store-self-improvement")
    XCTAssertEqual(audits.count, 2)
    XCTAssertEqual(audits.first?.operation, .updatePrompt)
    XCTAssertEqual(audits.first?.actor.id, "manual")
  }

  func testApplyValidationRejectsBeforeSubprocess() async throws {
    let cases = [
      ValidationCase(reason: "  ", patch: .array([.object(["op": .string("replace")])]), status: "rejected", expectedReason: "reasonRequired"),
      ValidationCase(reason: "valid reason", patch: .string("not an array"), status: "rejected", expectedReason: "invalidPatch"),
      ValidationCase(reason: "valid reason", patch: .array([]), status: "noChange", expectedReason: nil)
    ]
    for item in cases {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let runner = InProcessRielaCLIRunner()
      var command = WorkflowRunCommand()
      command.improvementCLIProcessRunnerOverride = runner
      _ = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
      try writeProposal(reason: item.reason, patch: item.patch, to: fixture.scenario)
      let second = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
      XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["status"], .string(item.status))
      XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["reason"], item.expectedReason.map(JSONValue.string))
      XCTAssertEqual(runner.invocationCount, 0)
    }
  }

  func testApplyRecursionGuardRejectsImprovementTargetsBeforeSubprocess() async throws {
    let promptPatch: JSONValue = .array([.object([
      "op": .string("replace"), "path": .string("/prompts~1improve-propose.md"),
      "value": .string("rewritten proposer prompt\n")
    ])])
    let inboundContextPatch: JSONValue = .array([.object([
      "op": .string("replace"), "path": .string("/workflow.json/steps/0/transitions/0/toStepId"),
      "value": .string("summarize")
    ])])
    let improveProposeTransitionPatch: JSONValue = .array([.object([
      "op": .string("remove"), "path": .string("/workflow.json/steps/1/transitions/0")
    ])])

    try await assertRecursionTargetPatchRejected(promptPatch, label: "improve-propose prompt")
    try await assertRecursionTargetPatchRejected(inboundContextPatch, label: "inbound improve-context transition")
    try await assertRecursionTargetPatchRejected(improveProposeTransitionPatch, label: "improvable transition to improve-propose")
  }

  func testApplyDuplicateRowsAreClosedWithoutCrashing() async throws {
    let cases = [
      DuplicateCase(
        patch: duplicateRowPatch(id: "summarize", nodeId: "summarize"),
        expectedReason: "invalid_definition",
        expectedInvocations: 1,
        label: "unrelated duplicate step"
      ),
      DuplicateCase(
        patch: duplicateRowPatch(id: "improve-context", nodeId: "improve-context"),
        expectedReason: "targetsImprovementNode",
        expectedInvocations: 0,
        label: "excluded duplicate step"
      )
    ]
    for item in cases {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let runner = InProcessRielaCLIRunner()
      var command = WorkflowRunCommand()
      command.improvementCLIProcessRunnerOverride = runner
      let first = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
      let seedVersion = try XCTUnwrap(first.session.definitionSource?.versionId)
      let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
      let historyCount = try store.history(workflowName: "definition-store-self-improvement").count

      try writeProposal(reason: "duplicate id test", patch: item.patch, to: fixture.scenario)
      let second = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))

      XCTAssertEqual(second.session.status, .completed, item.label)
      XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["status"], .string("rejected"), item.label)
      XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["reason"], .string(item.expectedReason), item.label)
      XCTAssertEqual(runner.invocationCount, item.expectedInvocations, item.label)
      XCTAssertEqual(try store.history(workflowName: "definition-store-self-improvement").count, historyCount, item.label)
      XCTAssertEqual(second.session.definitionSource?.versionId, seedVersion, item.label)
    }
  }

  private func assertRecursionTargetPatchRejected(_ patch: JSONValue, label: String) async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let runner = InProcessRielaCLIRunner()
    var command = WorkflowRunCommand()
    command.improvementCLIProcessRunnerOverride = runner
    let first = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))
    let seedVersion = try XCTUnwrap(first.session.definitionSource?.versionId)
    let store = WorkflowDefinitionStore(rootDirectory: fixture.store.path)
    let historyCount = try store.history(workflowName: "definition-store-self-improvement").count

    try writeProposal(reason: "valid recursion guard test", patch: patch, to: fixture.scenario)
    let second = try await run(command, fixture: fixture, mode: .service(.init(kind: .api, id: "test")))

    XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["status"], .string("rejected"), label)
    XCTAssertEqual(addonPayload(second, stepId: "improve-apply")?["reason"], .string("targetsImprovementNode"), label)
    XCTAssertEqual(runner.invocationCount, 0, label)
    XCTAssertEqual(try store.history(workflowName: "definition-store-self-improvement").count, historyCount, label)
    XCTAssertEqual(second.session.definitionSource?.versionId, seedVersion, label)
  }

  func testDigestBoundsPrioritizesFailuresAndIsDeterministic() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var executions: [WorkflowStepExecution] = []
    for index in 0..<30 {
      let status: WorkflowStepExecutionStatus = index % 10 == 0 ? .failed : .completed
      let attempt = index % 10 == 1 ? 2 : 1
      executions.append(WorkflowStepExecution(
        executionId: "execution-\(index)", stepId: "step-\(index)", nodeId: "node-\(index)",
        attempt: attempt,
        status: status,
        failureReason: index == 0 ? String(repeating: "x", count: 5_000) : nil,
        createdAt: now.addingTimeInterval(Double(index)), updatedAt: now.addingTimeInterval(Double(index))
      ))
    }
    let session = WorkflowSession(workflowId: "wf", sessionId: "session", status: .completed,
      entryStepId: "step-0", createdAt: now, updatedAt: now, executions: executions)
    let first = WorkflowImprovementDigest.build(session: session, excludedNodeIds: [], maxStepExecutions: 5, maxFieldChars: 100)
    let second = WorkflowImprovementDigest.build(session: session, excludedNodeIds: [], maxStepExecutions: 5, maxFieldChars: 100)
    XCTAssertEqual(first.digest, second.digest)
    XCTAssertEqual(first.digest.objectValue?["omittedCount"], JSONValue.integer(25))
    let entries = try XCTUnwrap(first.digest.objectValue?["stepExecutions"]?.arrayValue)
    XCTAssertEqual(entries.count, 5)
    XCTAssertEqual(entries.first?.objectValue?["stepExecutionId"], JSONValue.string("execution-1"))
    XCTAssertEqual(first.evidence.first?.kind, .session)
    XCTAssertEqual(first.evidence.dropFirst().map { $0.id }, entries.compactMap { $0.objectValue?["stepExecutionId"]?.stringValue })
    let longFailure = WorkflowStepExecution(
      executionId: "long", stepId: "long", nodeId: "long", attempt: 1, status: .failed,
      failureReason: String(repeating: "x", count: 5_000), createdAt: now, updatedAt: now
    )
    let longSession = WorkflowSession(workflowId: "wf", sessionId: "long-session", status: .failed,
      entryStepId: "long", createdAt: now, updatedAt: now, executions: [longFailure])
    let truncated = WorkflowImprovementDigest.build(session: longSession, excludedNodeIds: [], maxStepExecutions: 5, maxFieldChars: 100)
    let longEntry = try XCTUnwrap(truncated.digest.objectValue?["stepExecutions"]?.arrayValue?.first?.objectValue)
    XCTAssertEqual(longEntry["failureReason"]?.stringValue?.count, 100)
    XCTAssertEqual(longEntry["truncated"], JSONValue.bool(true))
  }

  func testRecursionGuardTracksImprovementFilesAndInboundChangesOnly() throws {
    let before = authoredView(proposalPrompt: "before", transitionTarget: "ordinary", includeEarlierNode: true)
    let changedNode = authoredView(proposalPrompt: "before", transitionTarget: "ordinary", includeEarlierNode: true, proposalDescription: "changed")
    let changedTransition = authoredView(proposalPrompt: "before", transitionTarget: "improve-propose", includeEarlierNode: true)
    let changedPrompt = authoredView(proposalPrompt: "changed", transitionTarget: "ordinary", includeEarlierNode: true)
    let changedTargetPrompt = authoredView(proposalPrompt: "before", transitionTarget: "ordinary", includeEarlierNode: true, summaryPrompt: "changed")
    let shifted = authoredView(proposalPrompt: "before", transitionTarget: "ordinary", includeEarlierNode: false)
    let excluded: Set<String> = ["improve-propose"]
    XCTAssertEqual(WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedNode, excludedNodeIds: excluded), ["improve-propose"])
    XCTAssertEqual(WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedTransition, excludedNodeIds: excluded), ["improve-propose"])
    XCTAssertEqual(WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedPrompt, excludedNodeIds: excluded), ["improve-propose"])
    XCTAssertTrue(WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedTargetPrompt, excludedNodeIds: excluded).isEmpty)
    XCTAssertTrue(WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: shifted, excludedNodeIds: excluded).isEmpty)
  }

  func testRecursionGuardUsesAuthoredStepAndNodeFileReferences() throws {
    let before = referencedAuthoredView()
    let changedStep = referencedAuthoredView(contextStepRole: "reviewer")
    let changedInboundTransition = referencedAuthoredView(inboundTarget: "output")
    let changedNodeFile = referencedAuthoredView(proposalDescription: "rewritten node")
    let changedVariantPrompt = referencedAuthoredView(reviewPrompt: "rewritten variant")
    let changedUnrelatedPrompt = referencedAuthoredView(summaryPrompt: "unrelated edit")
    let shifted = referencedAuthoredView(includeEarlierNode: true)
    let excluded: Set<String> = ["improve-context", "improve-propose"]

    XCTAssertEqual(
      WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedStep, excludedNodeIds: excluded),
      ["improve-context"]
    )
    XCTAssertEqual(
      WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedInboundTransition, excludedNodeIds: excluded),
      ["improve-context"]
    )
    XCTAssertEqual(
      WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedNodeFile, excludedNodeIds: excluded),
      ["improve-propose"]
    )
    XCTAssertEqual(
      WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedVariantPrompt, excludedNodeIds: excluded),
      ["improve-propose"]
    )
    XCTAssertTrue(WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: changedUnrelatedPrompt, excludedNodeIds: excluded).isEmpty)
    XCTAssertTrue(WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: shifted, excludedNodeIds: excluded).isEmpty)
  }

  func testRecursionGuardGroupsDuplicateRowsWithoutTrapping() throws {
    let before = referencedAuthoredView()
    let duplicateUnrelatedStep = try appendingWorkflowRow(
      .object(["id": .string("summary"), "nodeId": .string("summarize")]),
      collection: "steps",
      to: before
    )
    let duplicateExcludedStep = try appendingWorkflowRow(
      .object(["id": .string("ctx"), "nodeId": .string("improve-context")]),
      collection: "steps",
      to: before
    )
    let duplicateExcludedNode = try appendingWorkflowRow(
      .object(["id": .string("improve-propose"), "nodeFile": .string("nodes/proposer.json")]),
      collection: "nodes",
      to: before
    )
    let excluded: Set<String> = ["improve-context", "improve-propose"]

    XCTAssertTrue(
      WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: duplicateUnrelatedStep, excludedNodeIds: excluded).isEmpty
    )
    XCTAssertEqual(
      WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: duplicateExcludedStep, excludedNodeIds: excluded),
      ["improve-context"]
    )
    XCTAssertEqual(
      WorkflowImprovementDigest.touchedExcludedNodes(before: before, after: duplicateExcludedNode, excludedNodeIds: excluded),
      ["improve-propose"]
    )
  }

  private func appendingWorkflowRow(_ row: JSONValue, collection: String, to view: JSONValue) throws -> JSONValue {
    guard case var .object(files) = view,
          case var .object(workflow)? = files["workflow.json"],
          case var .array(rows)? = workflow[collection] else {
      throw XCTSkip("authored workflow fixture shape changed")
    }
    rows.append(row)
    workflow[collection] = .array(rows)
    files["workflow.json"] = .object(workflow)
    return .object(files)
  }

  private func duplicateRowPatch(id: String, nodeId: String) -> JSONValue {
    .array([.object([
      "op": .string("add"),
      "path": .string("/workflow.json/steps/-"),
      "value": .object(["id": .string(id), "nodeId": .string(nodeId), "role": .string("worker")])
    ])])
  }

  private func authoredView(
    proposalPrompt: String, transitionTarget: String, includeEarlierNode: Bool,
    proposalDescription: String = "stable", summaryPrompt: String = "summary"
  ) -> JSONValue {
    let nodes: [JSONValue] = (includeEarlierNode ? ["earlier"] : []).map { .object(["id": .string($0)]) } + [
      .object(["id": .string("improve-propose"), "nodeFile": .string("nodes/node-improve-propose.json")]),
      .object(["id": .string("summarize"), "nodeFile": .string("nodes/node-summarize.json")]),
      .object(["id": .string("ordinary")])
    ]
    let workflow: JSONValue = .object([
      "nodes": .array(nodes),
      "steps": .array([
        .object(["id": .string("source"), "nodeId": .string("summarize"), "transitions": .array([.object(["toStepId": .string(transitionTarget)])])]),
        .object(["id": .string("improve-propose"), "nodeId": .string("improve-propose")]),
        .object(["id": .string("summarize"), "nodeId": .string("summarize")]),
        .object(["id": .string("ordinary"), "nodeId": .string("ordinary")])
      ])
    ])
    return .object([
      "workflow.json": workflow,
      "nodes/node-improve-propose.json": .object(["id": .string("improve-propose"), "description": .string(proposalDescription), "promptTemplateFile": .string("prompts/improve-propose.md")]),
      "nodes/node-summarize.json": .object(["id": .string("summarize"), "promptTemplateFile": .string("prompts/summarize.md")]),
      "prompts/improve-propose.md": .string(proposalPrompt), "prompts/summarize.md": .string(summaryPrompt)
    ])
  }

  private func referencedAuthoredView(
    contextStepRole: String = "worker",
    inboundTarget: String = "ctx",
    proposalDescription: String = "stable",
    reviewPrompt: String = "review prompt",
    summaryPrompt: String = "summary prompt",
    includeEarlierNode: Bool = false
  ) -> JSONValue {
    var nodes: [JSONValue] = [
      .object(["id": .string("improve-context"), "nodeFile": .string("nodes/context.json")]),
      .object(["id": .string("improve-propose"), "nodeFile": .string("nodes/proposer.json")]),
      .object(["id": .string("summarize"), "nodeFile": .string("nodes/summarizer.json")]),
      .object(["id": .string("workflow-output"), "nodeFile": .string("nodes/output.json")])
    ]
    if includeEarlierNode { nodes.insert(.object(["id": .string("unrelated")]), at: 0) }
    let workflow: JSONValue = .object([
      "nodes": .array(nodes),
      "steps": .array([
        .object(["id": .string("summary"), "nodeId": .string("summarize"), "transitions": .array([.object(["toStepId": .string(inboundTarget)])])]),
        .object(["id": .string("ctx"), "nodeId": .string("improve-context"), "role": .string(contextStepRole), "transitions": .array([.object(["toStepId": .string("proposal")])])]),
        .object(["id": .string("proposal"), "nodeId": .string("improve-propose")]),
        .object(["id": .string("output"), "nodeId": .string("workflow-output")])
      ])
    ])
    return .object([
      "workflow.json": workflow,
      "nodes/context.json": .object(["id": .string("improve-context")]),
      "nodes/proposer.json": .object([
        "id": .string("improve-propose"),
        "description": .string(proposalDescription),
        "promptVariants": .object(["review": .object(["promptTemplateFile": .string("assets/review.md")])])
      ]),
      "nodes/summarizer.json": .object(["id": .string("summarize"), "promptTemplateFile": .string("assets/summary.md")]),
      "nodes/output.json": .object(["id": .string("workflow-output")]),
      "assets/review.md": .string(reviewPrompt),
      "assets/summary.md": .string(summaryPrompt)
    ])
  }

  private struct Fixture { let root: URL; let workflow: URL; let scenario: URL; let store: URL; let projectWorkflowLayout: Bool }

  private func makeFixture(projectWorkflowLayout: Bool = false) throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/efficient-history/improvement-node-\(UUID().uuidString)", isDirectory: true)
    let workflow = projectWorkflowLayout
      ? root.appendingPathComponent(".riela/workflows/definition-store-self-improvement", isDirectory: true)
      : root.appendingPathComponent("definition-store-self-improvement", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflow.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repositoryRoot().appendingPathComponent("examples/definition-store-self-improvement"), to: workflow)
    return Fixture(root: root, workflow: workflow, scenario: workflow.appendingPathComponent("mock-scenario.json"),
      store: root.appendingPathComponent("store", isDirectory: true), projectWorkflowLayout: projectWorkflowLayout)
  }

  private func repositoryRoot() -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

  private func run(_ command: WorkflowRunCommand, fixture: Fixture, mode: WorkflowExecutionMode) async throws -> WorkflowRunResult {
    var options = WorkflowRunOptions(
      target: "definition-store-self-improvement",
      resolution: WorkflowResolutionOptions(
        workflowName: "definition-store-self-improvement",
        scope: fixture.projectWorkflowLayout ? .project : .direct,
        workflowDefinitionDir: fixture.projectWorkflowLayout ? nil : fixture.root.path,
        workingDirectory: fixture.root.path
      ),
      mockScenarioPath: fixture.scenario.path,
      output: .json,
      sessionStore: fixture.store.path,
      workingDirectory: fixture.workflow.path
    )
    options.executionMode = mode
    let result = await command.run(options)
    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
  }

  private func addonPayload(_ result: WorkflowRunResult, stepId: String) -> JSONObject? {
    result.session.executions.first(where: { $0.stepId == stepId })?.acceptedOutput?.payload
  }

  private func definitionRowCounts(root: String) throws -> [Int] {
    let database = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root)),
      mode: .strictReadOnly,
      options: .readOnlyDefault
    )
      return try ["definition_history_versions", "definition_versions", "definition_heads", "definition_change_audit"].map { table in
      Int(try XCTUnwrap(database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"])) ?? -1
    }
  }

  private func fileDigests(root: URL) throws -> [String: String] {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    var result: [String: String] = [:]
    while let url = enumerator?.nextObject() as? URL {
      guard !url.hasDirectoryPath else { continue }
      let data = try Data(contentsOf: url)
      result[url.path.replacingOccurrences(of: root.path + "/", with: "")] = JSONCanonical.sha256Hex(data)
    }
    return result
  }

  private func writeProposal(reason: String, patch: JSONValue, to url: URL) throws {
    let data = try Data(contentsOf: url)
    guard case var .object(root) = try JSONDecoder().decode(JSONValue.self, from: data),
          case var .object(proposer) = root["improve-propose"],
          case var .object(payload) = proposer["payload"] else { throw XCTSkip("mock scenario shape changed") }
    payload["reason"] = .string(reason)
    payload["patch"] = patch
    proposer["payload"] = .object(payload)
    root["improve-propose"] = .object(proposer)
    try JSONEncoder().encode(JSONValue.object(root)).write(to: url, options: .atomic)
  }
}

private final class InProcessRielaCLIRunner: LocalProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var invocationCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
  private func recordInvocation() { lock.lock(); calls += 1; lock.unlock() }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    recordInvocation()
    var arguments = configuration.arguments
    if arguments.first == "riela" { arguments.removeFirst() }
    let result = await RielaCLIApplication().run(arguments)
    return LocalProcessResult(stdout: result.stdout, stderr: result.stderr, terminationStatus: result.exitCode.rawValue)
  }
}

private struct HeadMovingCLIRunner: LocalProcessRunning {
  let inner: InProcessRielaCLIRunner
  let storeRoot: String

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    var arguments = configuration.arguments
    if arguments.first == "riela" { arguments.removeFirst() }
    if Array(arguments.prefix(3)) == ["workflow", "definition", "update"] {
      _ = try WorkflowDefinitionService(storeRoot: storeRoot, fileResolver: FileSystemWorkflowBundleResolver()).updatePrompt(
        workflowName: "definition-store-self-improvement",
        nodeId: "summarize",
        field: .node(.promptTemplate),
        text: "MANUAL\n",
        reason: "manual",
        expectedVersionId: nil,
        evidence: [],
        actor: .init(kind: .cli, id: "manual")
      )
    }
    return try await inner.run(configuration: configuration, stdin: stdin, deadline: deadline)
  }
}

private extension JSONValue {
  var objectValue: JSONObject? { if case let .object(value) = self { return value }; return nil }
  var arrayValue: [JSONValue]? { if case let .array(value) = self { return value }; return nil }
}
