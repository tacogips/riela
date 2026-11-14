import Foundation
import RielaCore
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class WorkflowTaskAddonTests: XCTestCase {
  func testScaffolderKeepsTaskPromptOutsideWorkflowAndNodeJSON() throws {
    let root = temporaryRoot("bundle")
    defer { try? FileManager.default.removeItem(at: root) }
    let request = GeneratedWorkflowTaskRequest(
      title: "Investigate recurring sign-in failures",
      prompt: "Review the supplied evidence and return a concise remediation plan."
    )
    let configuration = taskConfiguration()

    let workflowId = generatedWorkflowId(request: request, configuration: configuration)
    _ = try WorkflowBundleScaffolder().create(
      at: root,
      specification: WorkflowBundleScaffoldSpecification(
        workflowId: workflowId,
        description: request.title,
        nodeId: "task-worker",
        executionBackend: configuration.executionBackend,
        model: configuration.model,
        modelFreeze: true,
        prompt: request.prompt,
        maxLoopIterations: 1,
        nodeTimeoutMs: 180_000
      )
    )

    XCTAssertTrue(workflowId.hasPrefix("test-task-investigate-recurring-sign-in-failures-"))
    XCTAssertLessThanOrEqual(workflowId.count, 64)
    let workflowText = try String(contentsOf: root.appendingPathComponent("workflow.json"), encoding: .utf8)
    let nodeText = try String(
      contentsOf: root.appendingPathComponent("nodes/node-task-worker.json"),
      encoding: .utf8
    )
    let promptText = try String(
      contentsOf: root.appendingPathComponent("prompts/task-worker.md"),
      encoding: .utf8
    )
    XCTAssertFalse(workflowText.contains(request.prompt))
    XCTAssertFalse(nodeText.contains(request.prompt))
    XCTAssertTrue(nodeText.contains(#""promptTemplateFile" : "prompts/task-worker.md""#))
    XCTAssertEqual(promptText, request.prompt + "\n")

    let bundle = try WorkflowRegistryBundleLoader().loadBundle(
      at: root,
      rootDirectory: root.deletingLastPathComponent(),
      scope: .direct,
      expectedWorkflowId: workflowId
    )
    XCTAssertEqual(bundle.workflow.workflowId, workflowId)
    XCTAssertEqual(bundle.nodePayloads["task-worker"]?.promptTemplate, request.prompt + "\n")
  }

  func testDefaultExecutorCreatesRegistersRunsAndRemovesStagingBundle() async throws {
    let staging = temporaryRoot("executor")
    let registrar = RecordingGeneratedWorkflowRegistrar()
    let runner = RecordingGeneratedWorkflowRunner()
    let executor = DefaultGeneratedWorkflowTaskExecutor(
      registrar: registrar,
      runner: runner,
      temporaryDirectory: { staging }
    )

    let result = try await executor.execute(
      request: GeneratedWorkflowTaskRequest(title: "Summarize audit", prompt: "Return the audit summary."),
      configuration: taskConfiguration(),
      workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )

    let registration = try XCTUnwrap(registrar.snapshot())
    XCTAssertEqual(registration.workflowId, result.workflowId)
    XCTAssertTrue(registration.nodeJSON.contains("prompts/task-worker.md"))
    XCTAssertEqual(registration.prompt, "Return the audit summary.\n")
    let workflowIds = await runner.workflowIds()
    XCTAssertEqual(workflowIds, [result.workflowId])
    XCTAssertEqual(result.runResult.rootOutput?["replyText"], .string("generated result"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
  }

  func testAddonUsesTaskSpecificationAndPreservesHandoffFlags() async throws {
    let executor = RecordingGeneratedWorkflowExecutor()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: [:],
      workflowTaskExecutor: executor
    )
    let output = try await resolver.execute(
      workflowTaskInput(
        config: taskConfigJSON(),
        payload: [
          "replyText": .string("initial reply"),
          "llm_only": .bool(false),
          "run_workflow": .bool(true),
          "handoff_specialist": .bool(true),
          "workflowTask": .object([
            "title": .string("Analyze evidence"),
            "prompt": .string("Analyze the authorized evidence and report findings.")
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let recordedInvocation = await executor.invocation()
    let invocation = try XCTUnwrap(recordedInvocation)
    XCTAssertEqual(invocation.request.title, "Analyze evidence")
    XCTAssertEqual(invocation.request.prompt, "Analyze the authorized evidence and report findings.")
    XCTAssertEqual(invocation.configuration.executionBackend, .officialOpenAISDK)
    XCTAssertEqual(output.payload["generatedWorkflowRegistered"], .bool(true))
    XCTAssertEqual(output.payload["generatedWorkflowExecuted"], .bool(true))
    XCTAssertEqual(output.payload["replyText"], .string("generated result"))
    XCTAssertEqual(output.when["handoff_specialist"], true)
  }

  func testAddonFailsClosedWithoutOptInOrTaskSpecification() async throws {
    let executor = RecordingGeneratedWorkflowExecutor()
    let resolver = BuiltinWorkflowAddonResolver(environment: [:], workflowTaskExecutor: executor)

    await XCTAssertThrowsErrorAsync {
      _ = try await resolver.execute(
        self.workflowTaskInput(
          config: [
            "executionBackend": .string("official/openai-sdk"),
            "model": .string("test-model")
          ],
          payload: self.validTaskPayload()
        ),
        context: AdapterExecutionContext()
      )
    }
    await XCTAssertThrowsErrorAsync {
      var payload = self.validTaskPayload()
      payload.removeValue(forKey: "workflowTask")
      _ = try await resolver.execute(
        self.workflowTaskInput(config: self.taskConfigJSON(), payload: payload),
        context: AdapterExecutionContext()
      )
    }
    let invocation = await executor.invocation()
    XCTAssertNil(invocation)
  }

  private func workflowTaskInput(
    config: JSONObject,
    payload: JSONObject
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "example-chat",
      stepId: "create-task",
      nodeId: "create-task",
      addon: WorkflowNodeAddonRef(
        name: "riela/workflow-create-register-run",
        version: "1",
        config: config
      ),
      resolvedInputPayload: payload
    )
  }

  private func validTaskPayload() -> JSONObject {
    [
      "llm_only": .bool(false),
      "run_workflow": .bool(true),
      "workflowTask": .object([
        "title": .string("Task title"),
        "prompt": .string("Task prompt")
      ])
    ]
  }

  private func taskConfigJSON() -> JSONObject {
    [
      "allowWorkflowCreation": .bool(true),
      "executionBackend": .string("official/openai-sdk"),
      "model": .string("test-model"),
      "workflowIdPrefix": .string("test-task")
    ]
  }

  private func taskConfiguration() -> GeneratedWorkflowTaskConfiguration {
    GeneratedWorkflowTaskConfiguration(
      executionBackend: .officialOpenAISDK,
      model: "test-model",
      workflowIdPrefix: "test-task",
      maxPromptBytes: 65_536
    )
  }

  private func temporaryRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-workflow-task-addon-\(label)-\(UUID().uuidString)", isDirectory: true)
  }
}

private actor RecordingGeneratedWorkflowExecutor: GeneratedWorkflowTaskExecuting {
  struct Invocation: Equatable, Sendable {
    var request: GeneratedWorkflowTaskRequest
    var configuration: GeneratedWorkflowTaskConfiguration
  }

  private var recordedInvocation: Invocation?

  func execute(
    request: GeneratedWorkflowTaskRequest,
    configuration: GeneratedWorkflowTaskConfiguration,
    workingDirectory _: URL
  ) async throws -> GeneratedWorkflowTaskResult {
    recordedInvocation = Invocation(request: request, configuration: configuration)
    return GeneratedWorkflowTaskResult(
      workflowId: "test-task-generated-123456789abc",
      workflowDirectory: "/registered/test-task-generated-123456789abc",
      overwritten: false,
      runResult: completedGeneratedWorkflowResult()
    )
  }

  func invocation() -> Invocation? { recordedInvocation }
}

private final class RecordingGeneratedWorkflowRegistrar: GeneratedWorkflowTaskRegistering, @unchecked Sendable {
  struct Snapshot: Equatable {
    var workflowId: String
    var nodeJSON: String
    var prompt: String
  }

  private let lock = NSLock()
  private var recorded: Snapshot?

  func register(bundle: URL, workingDirectory _: URL) throws -> GeneratedWorkflowTaskRegistration {
    let workflowData = try Data(contentsOf: bundle.appendingPathComponent("workflow.json"))
    let workflowId = try JSONDecoder().decode(WorkflowIdOnly.self, from: workflowData).workflowId
    let nodeJSON = try String(
      contentsOf: bundle.appendingPathComponent("nodes/node-task-worker.json"),
      encoding: .utf8
    )
    let prompt = try String(
      contentsOf: bundle.appendingPathComponent("prompts/task-worker.md"),
      encoding: .utf8
    )
    lock.lock()
    recorded = Snapshot(workflowId: workflowId, nodeJSON: nodeJSON, prompt: prompt)
    lock.unlock()
    return GeneratedWorkflowTaskRegistration(workflowDirectory: "/registered/\(workflowId)", overwritten: false)
  }

  func snapshot() -> Snapshot? {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

private actor RecordingGeneratedWorkflowRunner: GeneratedWorkflowTaskRunning {
  private var recordedWorkflowIds: [String] = []

  func run(workflowId: String, workingDirectory _: URL) async throws -> WorkflowRunResult {
    recordedWorkflowIds.append(workflowId)
    return completedGeneratedWorkflowResult(workflowId: workflowId)
  }

  func workflowIds() -> [String] { recordedWorkflowIds }
}

private struct WorkflowIdOnly: Decodable {
  var workflowId: String
}

private func completedGeneratedWorkflowResult(
  workflowId: String = "test-task-generated-123456789abc"
) -> WorkflowRunResult {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  return WorkflowRunResult(
    workflowId: workflowId,
    session: WorkflowSession(
      workflowId: workflowId,
      sessionId: "generated-session",
      status: .completed,
      entryStepId: "task-worker",
      createdAt: date,
      updatedAt: date
    ),
    rootOutput: ["replyText": .string("generated result")],
    exitCode: 0,
    transitions: 0
  )
}

private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("expected expression to throw", file: file, line: line)
  } catch {}
}
