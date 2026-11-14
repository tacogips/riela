import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func assertScopedProjectWorkflowEscapeRejected(workingDirectory: URL, workflowName: String = "escape") async throws {
    let validate = await RielaCLIApplication().run([
      "workflow", "validate", workflowName,
      "--scope", "project",
      "--working-dir", workingDirectory.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertFalse(validateFailure.valid)
    XCTAssertEqual(validateFailure.workflowId, workflowName)
    XCTAssertTrue(validateFailure.error.contains("escapes"))

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", workflowName,
      "--scope", "project",
      "--working-dir", workingDirectory.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .failure)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.workflowId, workflowName)
    XCTAssertTrue(inspectFailure.error.contains("escapes"))

    let run = await RielaCLIApplication().run([
      "workflow", "run", workflowName,
      "--scope", "project",
      "--working-dir", workingDirectory.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let runFailure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(runFailure.target, workflowName)
    XCTAssertTrue(runFailure.error.contains("escapes"))
  }

  func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(stdout.utf8))
  }

  func packageChecksum(packageRoot: URL) throws -> String {
    try WorkflowPackageChecksum.md5(packageRoot: packageRoot)
  }

  func rawDailySummaryVariables(
    provider: String = "telegram",
    text: String,
    eventId: String,
    receivedAt: String,
    attachments: [JSONValue] = []
  ) -> JSONObject {
    [
      "workflowInput": .object([
        "provider": .string(provider),
        "text": .string(text),
        "eventId": .string(eventId),
        "conversationId": .string("chat-1"),
        "receivedAt": .string(receivedAt)
      ]),
      "event": .object([
        "provider": .string(provider),
        "eventId": .string(eventId),
        "receivedAt": .string(receivedAt),
        "input": .object([
          "provider": .string(provider),
          "text": .string(text),
          "attachments": .array(attachments)
        ]),
        "conversation": .object([
          "id": .string("chat-1"),
          "threadId": .string("topic-a")
        ]),
        "actor": .object([
          "id": .string("user-1"),
          "displayName": .string("Memory User")
        ])
      ])
    ]
  }

  func objectPayload(_ value: MemoryJSONValue) -> [String: MemoryJSONValue]? {
    guard case let .object(object) = value else {
      return nil
    }
    return object
  }

  func memoryString(_ value: MemoryJSONValue?) -> String? {
    guard case let .string(string)? = value else {
      return nil
    }
    return string
  }

  func memoryNumber(_ value: MemoryJSONValue?) -> Int? {
    guard case let .number(number)? = value, number.rounded() == number else {
      return nil
    }
    return Int(number)
  }

  func memoryInt64Array(_ value: MemoryJSONValue?) -> [Int64] {
    guard case let .array(values)? = value else {
      return []
    }
    return values.compactMap { value in
      guard case let .number(number) = value else {
        return nil
      }
      return Int64(exactly: number)
    }
  }

  func repositoryRoot() -> String {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url.path
      }
      url.deleteLastPathComponent()
    }
    return FileManager.default.currentDirectoryPath
  }

  func writeTwoStepWorkflow(at root: URL, workflowName: String) throws -> (workflowDirectory: URL, scenarioPath: String) {
    let workflowDirectory = root.appendingPathComponent(workflowName, isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory.appendingPathComponent("nodes", isDirectory: true), withIntermediateDirectories: true)
    try """
    {
      "workflowId": "\(workflowName)",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "step-a",
      "nodes": [
        { "id": "node-a", "nodeFile": "nodes/node-a.json" },
        { "id": "node-b", "nodeFile": "nodes/node-b.json" }
      ],
      "steps": [
        { "id": "step-a", "nodeId": "node-a", "role": "worker", "transitions": [{ "toStepId": "step-b" }] },
        { "id": "step-b", "nodeId": "node-b", "role": "worker" }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"node-a","executionBackend":"codex-agent","model":"gpt-5.5","modelFreeze":false,"variables":{}}"#
      .write(to: workflowDirectory.appendingPathComponent("nodes/node-a.json"), atomically: true, encoding: .utf8)
    try #"{"id":"node-b","executionBackend":"codex-agent","model":"gpt-5.5","modelFreeze":false,"variables":{}}"#
      .write(to: workflowDirectory.appendingPathComponent("nodes/node-b.json"), atomically: true, encoding: .utf8)
    let scenarioURL = root.appendingPathComponent("\(workflowName)-scenario.json")
    try """
    {
      "step-a": {"provider":"scenario-mock","model":"gpt-5.5","when":{"always":true},"payload":{"status":"first"}},
      "step-b": {"provider":"scenario-mock","model":"gpt-5.5","when":{"always":true},"payload":{"status":"second"}}
    }
    """.write(to: scenarioURL, atomically: true, encoding: .utf8)
    return (workflowDirectory, scenarioURL.path)
  }

  struct IsolatedUserScopeWorkflowLayout {
    let base: URL
    let homeRoot: URL
    let projectRoot: URL
  }

  func makeIsolatedUserScopeWorkflowLayout(
    repositoryRoot: String,
    workflowName: String
  ) throws -> IsolatedUserScopeWorkflowLayout {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-user-scope-\(UUID().uuidString)", isDirectory: true)
    let homeRoot = base.appendingPathComponent("home", isDirectory: true)
    let projectRoot = base.appendingPathComponent("project", isDirectory: true)
    let userWorkflows = homeRoot
      .appendingPathComponent(".riela/workflows", isDirectory: true)
      .appendingPathComponent(workflowName, isDirectory: true)
    try FileManager.default.createDirectory(at: userWorkflows.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

    let sourceWorkflow = URL(fileURLWithPath: repositoryRoot)
      .appendingPathComponent("examples/\(workflowName)", isDirectory: true)
    if FileManager.default.fileExists(atPath: userWorkflows.path) {
      try FileManager.default.removeItem(at: userWorkflows)
    }
    try FileManager.default.copyItem(at: sourceWorkflow, to: userWorkflows)
    return IsolatedUserScopeWorkflowLayout(base: base, homeRoot: homeRoot, projectRoot: projectRoot)
  }

  func createExecutable(directory: URL, name: String, body: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try """
    #!/bin/sh
    \(body)
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}
