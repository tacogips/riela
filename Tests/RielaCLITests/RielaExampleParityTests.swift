import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RielaExampleParityTests: XCTestCase {
  private enum RepositoryPackage {
    static let manifestFileName = "Package.swift"
  }

  private enum ExampleCatalog {
    static let directoryName = "examples"
    static let expectedMockScenarioCount = 22
    static let expectedNodeMockScenarioCount = 0
  }

  private enum WorkflowPackage {
    static let manifestFileName = "workflow.json"
  }

  private enum MockScenario {
    static let fileName = "mock-scenario.json"
  }

  private enum WorkflowIds {
    static let defaultSuperviserWorkflowName = "default-superviser"
    static let defaultSuperviserWorkflowId = "riela-default-superviser"
    static let supervisedMockRetryWorkflowName = "supervised-mock-retry"
    static let telegramSDKTrioChatWorkflowName = "telegram-sdk-trio-chat"
  }

  private enum NodeRuntime {
    static let scriptsDirectoryName = "scripts"
    static let shellScriptExtension = "sh"
    static let nodeInvocationNeedles = ["\nnode ", "\nexec node "]
  }

  private enum WorkflowRunCLI {
    static let workflowRunArgumentsPrefix = ["workflow", "run"]
    static let workflowDefinitionDirFlag = "--workflow-definition-dir"
    static let mockScenarioFlag = "--mock-scenario"
    static let maxStepsFlag = "--max-steps"
    static let mockRunMaxSteps = "200"
    static let outputFlag = "--output"
    static let jsonOutputFormat = "json"
    static let autoImproveFlag = "--auto-improve"
  }

  private enum TelegramSDKTrioChatMock {
    static let variables = #"""
    {
      "workflowInput": {
        "text": "@rinacursor0529bot explain the SDK trio setup",
        "provider": "telegram"
      },
      "event": {
        "sourceId": "telegram-live",
        "eventId": "mock-1",
        "provider": "telegram",
        "eventType": "chat.message",
        "input": {
          "text": "@rinacursor0529bot explain the SDK trio setup",
          "provider": "telegram",
          "attachments": [],
          "imagePaths": [],
          "attachmentText": ""
        },
        "conversation": {
          "id": "100",
          "threadId": "topic-a"
        },
        "actor": {
          "id": "200",
          "displayName": "Mock User"
        }
      }
    }
    """#

    static func variables(text: String, eventId: String) -> String {
      #"""
      {
        "workflowInput": {
          "text": "\#(text)",
          "provider": "telegram"
        },
        "event": {
          "sourceId": "telegram-live",
          "eventId": "\#(eventId)",
          "provider": "telegram",
          "eventType": "chat.message",
          "input": {
            "text": "\#(text)",
            "provider": "telegram",
            "attachments": [],
            "imagePaths": [],
            "attachmentText": ""
          },
          "conversation": {
            "id": "100",
            "threadId": "topic-a"
          },
          "actor": {
            "id": "200",
            "displayName": "Mock User"
          }
        }
      }
      """#
    }
  }

  func testAllRielaExampleWorkflowsArePortedAndValidateInSwift() throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
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
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let app = RielaCLIApplication()
    let mockScenarioExamples = rielaExampleWorkflowNames().filter {
      hasMockScenario(examplesRoot: examplesRoot, workflowName: $0)
    }
    let nodeRuntimeMockScenarioExamples = mockScenarioExamples.filter {
      workflowUsesNodeRuntime(examplesRoot: examplesRoot, workflowName: $0)
    }

    XCTAssertEqual(mockScenarioExamples.count, ExampleCatalog.expectedMockScenarioCount)
    XCTAssertEqual(
      nodeRuntimeMockScenarioExamples.count,
      ExampleCatalog.expectedNodeMockScenarioCount
    )

    for workflowName in mockScenarioExamples {
      let scenario = examplesRoot
        .appendingPathComponent(workflowName, isDirectory: true)
        .appendingPathComponent(MockScenario.fileName)
      var arguments = WorkflowRunCLI.workflowRunArgumentsPrefix + [
        workflowName,
        WorkflowRunCLI.workflowDefinitionDirFlag, examplesRoot.path,
        WorkflowRunCLI.mockScenarioFlag, scenario.path,
        WorkflowRunCLI.maxStepsFlag, WorkflowRunCLI.mockRunMaxSteps,
        WorkflowRunCLI.outputFlag, WorkflowRunCLI.jsonOutputFormat
      ]
      if workflowName == WorkflowIds.supervisedMockRetryWorkflowName {
        arguments.append(WorkflowRunCLI.autoImproveFlag)
      }
      if workflowName == WorkflowIds.telegramSDKTrioChatWorkflowName {
        arguments.append(contentsOf: ["--variables", TelegramSDKTrioChatMock.variables])
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

  func testTelegramSDKTrioChatMentionRoutingProducesRootReplies() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let scenario = examplesRoot
      .appendingPathComponent(WorkflowIds.telegramSDKTrioChatWorkflowName, isDirectory: true)
      .appendingPathComponent(MockScenario.fileName)
    let cases = [
      ("rina", "@rinacursor0529bot explain the SDK trio setup", "rina"),
      ("mika", "@mikatrend0529bot give a short plan", "mika"),
      ("yui-default", "Please summarize today's plan", "yui"),
      ("concatenated-mika", "Mikausersidecheck.Replyshort.", "yui")
    ]
    let app = RielaCLIApplication()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    for (eventId, text, expectedReplyAs) in cases {
      let result = await app.run(WorkflowRunCLI.workflowRunArgumentsPrefix + [
        WorkflowIds.telegramSDKTrioChatWorkflowName,
        WorkflowRunCLI.workflowDefinitionDirFlag, examplesRoot.path,
        WorkflowRunCLI.mockScenarioFlag, scenario.path,
        WorkflowRunCLI.outputFlag, WorkflowRunCLI.jsonOutputFormat,
        "--variables", TelegramSDKTrioChatMock.variables(text: text, eventId: eventId)
      ])

      XCTAssertEqual(result.exitCode, .success, "\(eventId): \(result.stderr)\n\(result.stdout)")
      let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(payload.status, .completed, eventId)
      XCTAssertEqual(payload.rootOutput?["replyAs"], .string(expectedReplyAs), eventId)
      XCTAssertEqual(payload.rootOutput?["status"], .string("ok"), eventId)
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
      "gemini-ocr-worker",
      "gemini-sdk-worker",
      "gmail-latest-mail-digest-telegram",
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
    workflowName == WorkflowIds.defaultSuperviserWorkflowName
      ? WorkflowIds.defaultSuperviserWorkflowId
      : workflowName
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
      let workflowPath = url.appendingPathComponent(WorkflowPackage.manifestFileName).path
      guard FileManager.default.fileExists(atPath: workflowPath) else {
        return nil
      }
      return url.lastPathComponent
    }.sorted()
  }

  private func hasMockScenario(examplesRoot: URL, workflowName: String) -> Bool {
    let scenario = examplesRoot
      .appendingPathComponent(workflowName, isDirectory: true)
      .appendingPathComponent(MockScenario.fileName)
    return FileManager.default.fileExists(atPath: scenario.path)
  }

  private func workflowUsesNodeRuntime(examplesRoot: URL, workflowName: String) -> Bool {
    let scriptsRoot = examplesRoot
      .appendingPathComponent(workflowName, isDirectory: true)
      .appendingPathComponent(NodeRuntime.scriptsDirectoryName, isDirectory: true)
    guard
      let scripts = try? FileManager.default.contentsOfDirectory(
        at: scriptsRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }
    return scripts.contains { script in
      guard
        script.pathExtension == NodeRuntime.shellScriptExtension,
        let text = try? String(contentsOf: script, encoding: .utf8)
      else {
        return false
      }
      return NodeRuntime.nodeInvocationNeedles.contains { text.contains($0) }
    }
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(RepositoryPackage.manifestFileName).path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}
