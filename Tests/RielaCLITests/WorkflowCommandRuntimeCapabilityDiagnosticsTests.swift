import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testWorkflowValidateReportsRuntimeCapabilityGaps() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-capability-gap-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("fanout-gap", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "fanout-gap",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "start",
      "nodes": [
        { "id": "start-node", "nodeFile": "nodes/start.json" },
        { "id": "worker-node", "nodeFile": "nodes/worker.json" },
        { "id": "join-node", "nodeFile": "nodes/join.json" }
      ],
      "steps": [
        {
          "id": "start",
          "nodeId": "start-node",
          "transitions": [
            {
              "toStepId": "worker",
              "fanout": { "groupId": "items", "itemsFrom": "/items", "joinStepId": "join" }
            }
          ]
        },
        { "id": "worker", "nodeId": "worker-node" },
        { "id": "join", "nodeId": "join-node" }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    for nodeName in ["start", "worker", "join"] {
      try """
      {
        "id": "\(nodeName)-node",
        "executionBackend": "codex-agent",
        "model": "gpt-5.5"
      }
      """.write(to: nodesDirectory.appendingPathComponent("\(nodeName).json"), atomically: true, encoding: .utf8)
    }

    let result = await RielaCLIApplication().run([
      "workflow", "validate", "fanout-gap",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: result.stdout)
    XCTAssertFalse(validation.valid)
    XCTAssertTrue(validation.diagnostics.contains { diagnostic in
      diagnostic.path == "workflow.steps.start.transitions.fanout" &&
        diagnostic.message == "step 'start' uses fanout transitions, which this runner does not support yet"
    })

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "fanout-gap",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])

    XCTAssertEqual(inspect.exitCode, .success)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertTrue(summary.runtimeCapabilityGaps.contains { diagnostic in
      diagnostic.path == "workflow.steps.start.transitions.fanout" &&
        diagnostic.message == "step 'start' uses fanout transitions, which this runner does not support yet"
    })
  }

  func testValidateAndInspectReportMissingCrossWorkflowCallee() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-missing-callee-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("missing-callee", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "missing-callee",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "start",
      "nodes": [
        { "id": "start-node", "nodeFile": "nodes/start.json" },
        { "id": "resume-node", "nodeFile": "nodes/resume.json" }
      ],
      "steps": [
        {
          "id": "start",
          "nodeId": "start-node",
          "transitions": [
            { "toWorkflowId": "absent-callee", "toStepId": "child-start", "resumeStepId": "resume" }
          ]
        },
        { "id": "resume", "nodeId": "resume-node" }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    for nodeName in ["start", "resume"] {
      try """
      {
        "id": "\(nodeName)-node",
        "executionBackend": "codex-agent",
        "model": "gpt-5.5"
      }
      """.write(to: nodesDirectory.appendingPathComponent("\(nodeName).json"), atomically: true, encoding: .utf8)
    }

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "missing-callee",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(validation.diagnostics.contains { diagnostic in
      diagnostic.severity == .error &&
        diagnostic.path == "workflow.steps.start.transitions.toWorkflowId" &&
        diagnostic.message.contains("absent-callee") &&
        diagnostic.message.contains("could not be resolved")
    })

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "missing-callee",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertTrue(summary.runtimeCapabilityGaps.contains { diagnostic in
      diagnostic.severity == .error &&
        diagnostic.path == "workflow.steps.start.transitions.toWorkflowId" &&
        diagnostic.message.contains("absent-callee") &&
        diagnostic.message.contains("could not be resolved")
      })
  }

  func testValidateAndInspectReportMissingCallerResumeStepForCrossWorkflowDispatch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-missing-resume-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("missing-resume", isDirectory: true)
    let calleeDirectory = root.appendingPathComponent("callee", isDirectory: true)
    let callerNodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let calleeNodesDirectory = calleeDirectory.appendingPathComponent("nodes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: callerNodesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: calleeNodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "missing-resume",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "start",
      "nodes": [
        { "id": "start-node", "nodeFile": "nodes/start.json" }
      ],
      "steps": [
        {
          "id": "start",
          "nodeId": "start-node",
          "transitions": [
            { "toWorkflowId": "callee", "toStepId": "child-start", "resumeStepId": "resume" }
          ]
        }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "workflowId": "callee",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "child-start",
      "nodes": [
        { "id": "child-node", "nodeFile": "nodes/child.json" }
      ],
      "steps": [
        { "id": "child-start", "nodeId": "child-node" }
      ]
    }
    """.write(to: calleeDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "start-node",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5"
    }
    """.write(to: callerNodesDirectory.appendingPathComponent("start.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "child-node",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5"
    }
    """.write(to: calleeNodesDirectory.appendingPathComponent("child.json"), atomically: true, encoding: .utf8)

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "missing-resume",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(validation.diagnostics.contains { diagnostic in
      diagnostic.severity == .error &&
        diagnostic.path == "workflow.steps.start.transitions.resumeStepId" &&
        diagnostic.message.contains("resume") &&
        diagnostic.message.contains("caller resume step does not exist")
    })

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "missing-resume",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertTrue(summary.runtimeCapabilityGaps.contains { diagnostic in
      diagnostic.severity == .error &&
        diagnostic.path == "workflow.steps.start.transitions.resumeStepId" &&
        diagnostic.message.contains("resume") &&
        diagnostic.message.contains("caller resume step does not exist")
    })
  }

  func testValidateAndInspectReportCrossWorkflowDispatchReachableOnlyThroughResumeStep() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-resume-dispatch-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("resume-dispatch-gap", isDirectory: true)
    let calleeDirectory = root.appendingPathComponent("callee", isDirectory: true)
    let callerNodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let calleeNodesDirectory = calleeDirectory.appendingPathComponent("nodes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: callerNodesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: calleeNodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "resume-dispatch-gap",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "start",
      "nodes": [
        { "id": "start-node", "nodeFile": "nodes/start.json" },
        { "id": "resume-node", "nodeFile": "nodes/resume.json" },
        { "id": "final-node", "nodeFile": "nodes/final.json" }
      ],
      "steps": [
        {
          "id": "start",
          "nodeId": "start-node",
          "transitions": [
            { "toWorkflowId": "callee", "toStepId": "child-start", "resumeStepId": "resume" }
          ]
        },
        {
          "id": "resume",
          "nodeId": "resume-node",
          "transitions": [
            { "toWorkflowId": "second-callee", "toStepId": "second-start", "resumeStepId": "final" }
          ]
        },
        { "id": "final", "nodeId": "final-node" }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "workflowId": "callee",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "child-start",
      "nodes": [
        { "id": "child-node", "nodeFile": "nodes/child.json" }
      ],
      "steps": [
        { "id": "child-start", "nodeId": "child-node" }
      ]
    }
    """.write(to: calleeDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    for nodeName in ["start", "resume", "final"] {
      try """
      {
        "id": "\(nodeName)-node",
        "executionBackend": "codex-agent",
        "model": "gpt-5.5"
      }
      """.write(to: callerNodesDirectory.appendingPathComponent("\(nodeName).json"), atomically: true, encoding: .utf8)
    }
    try """
    {
      "id": "child-node",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5"
    }
    """.write(to: calleeNodesDirectory.appendingPathComponent("child.json"), atomically: true, encoding: .utf8)

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "resume-dispatch-gap",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(validation.diagnostics.contains { diagnostic in
      diagnostic.severity == .error &&
        diagnostic.path == "workflow.steps.resume.transitions.toWorkflowId" &&
        diagnostic.message.contains("second-callee") &&
        diagnostic.message.contains("could not be resolved")
    })

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "resume-dispatch-gap",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertTrue(summary.runtimeCapabilityGaps.contains { diagnostic in
      diagnostic.severity == .error &&
        diagnostic.path == "workflow.steps.resume.transitions.toWorkflowId" &&
        diagnostic.message.contains("second-callee") &&
        diagnostic.message.contains("could not be resolved")
    })
  }
}
