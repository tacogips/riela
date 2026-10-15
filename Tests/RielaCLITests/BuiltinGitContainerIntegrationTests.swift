import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class BuiltinGitContainerIntegrationTests: XCTestCase {
  func testSQLiteReopenResumesAfterGuestCommitAndReconcilesDroppedAcknowledgment() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RIELA_TEST_LIVE_BUILTIN_IMAGE"] == "1", "opt-in real guest Git test")
    try await verifyReopen(sandbox: nil)
  }

  func testSeatbeltSQLiteReopenResumesAndReconcilesDroppedAcknowledgment() async throws {
    #if os(macOS)
    try await verifyReopen(sandbox: .init(backend: .seatbelt, readPaths: ["/Applications/Xcode.app/Contents"]))
    #else
    throw XCTSkip("macOS Seatbelt gate")
    #endif
  }

  private func verifyReopen(sandbox: WorkflowExecutionSandbox?) async throws {
    let repository = try GitTestRepository()
    try repository.write("container change", to: "tracked.txt")
    let image = ProcessInfo.processInfo.environment["RIELA_TEST_BUILTIN_IMAGE"] ?? WorkflowAddonContainerExecution.defaultImage
    let control = builtinContainerTransportRoot(for: repository.root, testCase: self)
    let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath()
    func resolver() -> BuiltinAddonContainerResolver {
      .init(transportRootDirectory: control, primary: repository.resolver, environment: ["RIELA_SANDBOX_WORKER_EXECUTABLE": worker.path], workingDirectory: repository.root)
    }
    var commit = makeGitCommitInput(message: "fixture", files: ["tracked.txt"]).addon
    commit.container = sandbox == nil ? .init(image: image, runtime: .appleContainer, networkPolicy: .denied) : nil
    commit.sandbox = sandbox
    let clock = WorkflowNodeAddonRef(name: "riela/time-signal", version: "1",
      inputs: ["scheduledAt": .string("2026-10-15T00:00:00Z"), "timezone": .string("UTC")],
      container: sandbox == nil ? .init(image: image, runtime: .appleContainer, networkPolicy: .denied) : nil, sandbox: sandbox)
    let workflow = WorkflowDefinition(workflowId: "guest-git-resume", defaults: .init(nodeTimeoutMs: 120_000, maxLoopIterations: 1),
      entryStepId: "commit", nodeRegistry: [.init(id: "commit", addon: commit), .init(id: "clock", addon: clock)],
      steps: [.init(id: "commit", nodeId: "commit", transitions: [.init(toStepId: "clock")]), .init(id: "clock", nodeId: "clock")],
      nodes: [.init(id: "commit", addon: commit), .init(id: "clock", addon: clock)])
    let variables: JSONObject = ["message": .string("test: guest commit"), "files": .array([.string("tracked.txt")])]
    let runtimeRoot = repository.root.deletingLastPathComponent().appendingPathComponent("runtime")
    let backing = InMemoryWorkflowRuntimeStore()
    let store = FailClosedSQLiteWorkflowRuntimeStore(backing: backing, rootDirectory: runtimeRoot.path)
    let first = DeterministicWorkflowRunner(store: store, addonResolver: DroppedContainerAcknowledgment(base: resolver()))
    do {
      _ = try await first.run(.init(workflow: workflow, variables: variables, maxSteps: 1))
      XCTFail("fixture must stop between the accepted commit and the next step")
    } catch DeterministicWorkflowRunnerError.maxStepsExceeded { /* Expected controlled runtime stop. */ }
    let maybeFailed = await backing.latestSession(workflowId: workflow.workflowId)
    let failed = try XCTUnwrap(maybeFailed)
    XCTAssertEqual(failed.failureKind, .maxStepsExceeded)
    let token = try XCTUnwrap(failed.executions.first?.acceptedOutput?.runtimeFinalizationToken)
    let revision = try repository.git(["rev-parse", "HEAD"]).trimmed
    XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "2")

    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot.path)
    let saved = try persistence.load(sessionId: failed.sessionId)
    XCTAssertEqual(saved.session.executions.first?.acceptedOutput?.runtimeFinalizationToken, token)
    let reopenedBacking = InMemoryWorkflowRuntimeStore()
    await reopenedBacking.seedSession(saved.session)
    await reopenedBacking.seedWorkflowMessages(saved.workflowMessages)
    let reopenedStore = FailClosedSQLiteWorkflowRuntimeStore(backing: reopenedBacking, rootDirectory: runtimeRoot.path)
    let fresh = resolver()
    let resumed = try await DeterministicWorkflowRunner(store: reopenedStore, addonResolver: fresh)
      .run(.init(workflow: workflow, variables: variables, maxSteps: 3, resumeSessionId: failed.sessionId))
    XCTAssertEqual(resumed.status, .completed)
    XCTAssertEqual(resumed.session.sessionId, failed.sessionId)
    XCTAssertEqual(resumed.session.executions.map(\.stepId), ["commit", "clock"])
    XCTAssertEqual(resumed.session.executions.first?.executionId, failed.executions.first?.executionId)
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, revision)
    let routing = BuiltinAddonContainerTransportStore(workingDirectory: repository.root, rootDirectory: control)
    XCTAssertTrue(try routing.isAcknowledged(token))
    XCTAssertTrue(try routing.invocations(workflowExecutionId: failed.sessionId).isEmpty)
    try await resolver().acknowledgeAcceptedFinalization(token)
    XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "2")
  }
}

private struct DroppedContainerAcknowledgment: WorkflowAddonResolving, WorkflowAddonFinalizationAcknowledging {
  let base: BuiltinAddonContainerResolver
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try await base.execute(input, context: context)
  }
  func acknowledgeAcceptedFinalization(_ token: WorkflowAddonFinalizationToken) async throws {
    throw AdapterExecutionError(.providerError, "fixture dropped acknowledgment after runtime publication")
  }
}
