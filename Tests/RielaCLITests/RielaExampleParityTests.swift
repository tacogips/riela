import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RielaExampleParityTests: XCTestCase {
  func testAllRielaExampleWorkflowsArePortedAndValidateInSwift() throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent("examples", isDirectory: true)
    let expectedWorkflowNames = rielaExampleWorkflowNames()
    let actualWorkflowNames = try discoverWorkflowNames(examplesRoot: examplesRoot)

    XCTAssertEqual(actualWorkflowNames, expectedWorkflowNames)

    let resolver = FileSystemWorkflowBundleResolver()
    for workflowName in expectedWorkflowNames {
      let bundle = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: workflowName,
        scope: .direct,
        workflowDefinitionDir: examplesRoot.path,
        workingDirectory: root.path
      ))
      let diagnostics = bundle.diagnostics + DefaultWorkflowValidator().validate(bundle.workflow)
      XCTAssertEqual(diagnostics.filter { $0.severity == .error }, [], workflowName)
      XCTAssertEqual(bundle.workflow.workflowId, expectedWorkflowId(for: workflowName))
    }
  }

  func testMockScenarioExamplesRunThroughSwiftCLI() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent("examples", isDirectory: true)
    let app = RielaCLIApplication()
    let runnableExamples = rielaExampleWorkflowNames().filter { workflowName in
      let scenario = examplesRoot
        .appendingPathComponent(workflowName, isDirectory: true)
        .appendingPathComponent("mock-scenario.json")
      guard FileManager.default.fileExists(atPath: scenario.path) else {
        return false
      }
      let text = (try? String(contentsOf: scenario, encoding: .utf8)) ?? ""
      return text.contains("scenario-mock")
    }

    XCTAssertEqual(runnableExamples.count, 20)

    for workflowName in runnableExamples {
      let scenario = examplesRoot
        .appendingPathComponent(workflowName, isDirectory: true)
        .appendingPathComponent("mock-scenario.json")
      var arguments = [
        "workflow", "run", workflowName,
        "--workflow-definition-dir", examplesRoot.path,
        "--mock-scenario", scenario.path,
        "--max-steps", "200",
        "--output", "json"
      ]
      if workflowName == "supervised-mock-retry" {
        arguments.append("--auto-improve")
      }
      let result = await app.run(arguments)

      XCTAssertEqual(result.exitCode, .success, "\(workflowName): \(result.stderr)\n\(result.stdout)")
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(payload.workflowId, workflowName)
      XCTAssertEqual(payload.status, .completed, workflowName)
    }
  }

  private func rielaExampleWorkflowNames() -> [String] {
    [
      "chat-event-attachment-judgement",
      "chat-reply-webhook",
      "chat-supervisor-collaboration",
      "claude-riela-claude-worker",
      "claude-riela-codex-coding",
      "codex-codex-topic-debate",
      "default-superviser",
      "design-and-implement-review-loop",
      "design-and-implement-review-loop-feature-plan",
      "discord-agent-trio-chat",
      "discord-codex-chat",
      "discord-persona-chat",
      "dispatcher-llm-resolver-stub",
      "first-four-arithmetic-pipeline",
      "matrix-agent-trio-chat",
      "matrix-chat-reply",
      "node-combinations-showcase",
      "recent-change-quality-loop",
      "riela-default-workflow-supervisor",
      "same-node-session-echo",
      "scheduled-sleep",
      "subworkflow-chained-simple",
      "supervised-mock-retry",
      "telegram-agent-trio-chat",
      "telegram-agent-trio-time-signal",
      "telegram-sdk-trio-chat",
      "worker-only-single-step",
      "workflow-call-review-target",
      "workflow-call-simple",
      "x-follower-ai-business-digest"
    ]
  }

  private func expectedWorkflowId(for workflowName: String) -> String {
    workflowName == "default-superviser" ? "riela-default-superviser" : workflowName
  }

  private func discoverWorkflowNames(examplesRoot: URL) throws -> [String] {
    let contents = try FileManager.default.contentsOfDirectory(
      at: examplesRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    return try contents.compactMap { url -> String? in
      guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        return nil
      }
      let workflowPath = url.appendingPathComponent("workflow.json").path
      guard FileManager.default.fileExists(atPath: workflowPath) else {
        return nil
      }
      return url.lastPathComponent
    }.sorted()
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}
