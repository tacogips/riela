import Crypto
import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class SpecialistClassificationReplayTests: XCTestCase {
  func testSealedExpiredStatusDecisionDoesNotInvokeModelAgain() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/classification-replay/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = Data(#"""
    {"specialists":[{"id":"engineering","capacity":1,"domain":"software","allowedOriginIds":["project"]}],
    "classifier":{"node":{"id":"planner","executionBackend":"official/openai-sdk","model":"fixture"}}}
    """#.utf8)
    let path = root.appendingPathComponent("classifier.json")
    try configuration.write(to: path)
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let request = SpecialistRequest(requestId: "request", sourceEventId: "request",
                                    principal: .init(accountId: "local", actorId: "operator", roomId: "local"), route: .work, body: "progress please")
    _ = try store.accept(request)
    let deadline = Date().addingTimeInterval(-60)
    _ = try store.beginClassificationRound(.init(requestId: request.requestId,
      configurationRevision: "sha256:" + SHA256.hash(data: configuration).map { String(format: "%02x", $0) }.joined(),
      catalogRevision: "pending-authorized-selection", deadline: deadline))
    _ = try store.sealClassificationRound(requestId: request.requestId,
      decisions: [.init(specialistId: "engineering", kind: .status, reason: "progress")], now: deadline.addingTimeInterval(-1))
    let result = await SpecialistCommandRunner(classifierAdapter: NeverInvokeReplayAdapter()).run(.init(kind: .submit,
      options: .init(scope: "specialist", command: "submit", target: "request", arguments: [
        "--state-root", root.path, "--working-dir", root.path, "--body", request.body, "--specialist-config", path.path
      ], output: .json)))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("status_reply_queued"))
    XCTAssertEqual(try store.pendingOutboxEvents().count, 1)
    XCTAssertTrue(try store.recoverableDispatches().isEmpty)
  }
}

private struct NeverInvokeReplayAdapter: NodeAdapter {
  func execute(_: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    XCTFail("A sealed decision must survive replay without another model call")
    throw SpecialistClassifierError.unavailable
  }
}
