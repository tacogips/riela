import XCTest
@testable import RielaCore

final class MediaDownloadDeprecationValidationTests: XCTestCase {
  func testOneWarningPerDeprecatedNode() {
    let diagnostics = validate(names: ["riela/media-download", "riela/media-download"])
    XCTAssertFalse(diagnostics.contains { $0.severity == .error })
    let warnings = diagnostics.filter { $0.message.contains("is deprecated") }
    XCTAssertEqual(warnings.count, 2)
    XCTAssertEqual(Set(warnings.map(\.path)), Set(["workflow.nodes.node0.addon.name", "workflow.nodes.node1.addon.name"]))
    XCTAssertTrue(warnings.allSatisfy { $0.severity == .warning && $0.message.contains("media/yt-dlp-download")
      && $0.message.contains("Migrating from riela/media-download") })
    XCTAssertEqual(validate(names: ["riela/media-download"]).filter { $0.message.contains("is deprecated") }.count, 1)
  }

  func testOtherMediaAddonsAreNotDeprecated() {
    let diagnostics = validate(names: ["riela/audio-segments", "riela/video-frames", "riela/speech-to-text"])
    XCTAssertFalse(diagnostics.contains { $0.message.contains("is deprecated") })
  }

  private func validate(names: [String]) -> [WorkflowValidationDiagnostic] {
    let nodes = names.enumerated().map { index, name in
      WorkflowNodeRegistryRef(id: "node\(index)", nodeFile: "nodes/node\(index).json", addon: .init(name: name))
    }
    let workflow = WorkflowDefinition(
      workflowId: "deprecation-test", defaults: .init(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "only", nodeRegistry: nodes, steps: [.init(id: "only", nodeId: "node0")],
      nodes: nodes.map { .init(id: $0.id, nodeFile: $0.nodeFile) }
    )
    return DefaultWorkflowValidator().validate(workflow)
  }
}
