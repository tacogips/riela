import Foundation
import RielaCore
import XCTest

final class ActivityCatalogReportTests: XCTestCase {
  func testLiveActivityPopulatesTheProviderReport() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-13-model-surfaces/activity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    let store = BotStore(sessionStoreRoot: root.path)
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    await recorder.stepStarted(
      sessionId: "session", executionId: "active", stepId: "step", nodeId: "node",
      backend: "codex-agent", requestedModel: nil, at: at
    )
    await recorder.record(
      sessionId: "session", executionId: "active", update: .configOptions(options: [[
        "id": .string("model"), "category": .string("model"),
        "values": .array([.string("live-model")])
      ]]), at: at
    )
    XCTAssertEqual(try store.providerReport(instanceId: "codex-agent")?.reportedModels.map(\.id), ["live-model"])
    await recorder.record(
      sessionId: "session", executionId: "active", update: .reportedModel("current-model"), at: at.addingTimeInterval(1)
    )
    await recorder.record(
      sessionId: "session", executionId: "stale", update: .reportedModel("stale-model"), at: at.addingTimeInterval(2)
    )
    let report = try XCTUnwrap(store.providerReport(instanceId: "codex-agent"))
    XCTAssertEqual(report.currentModel, "current-model")
    XCTAssertEqual(Set(report.reportedModels.map(\.id)), ["live-model", "current-model"])
    XCTAssertEqual(report.observedAt, at.addingTimeInterval(1))
  }
}
