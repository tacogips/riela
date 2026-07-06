import Foundation
import RielaAdapters
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

actor RecordingWorkflowGraphQLRunTransport: WorkflowGraphQLRunTransporting {
  private(set) var endpoint: String?
  private(set) var request: WorkflowRemoteRunRequest?
  var result = WorkflowRemoteRunResult(
    sessionId: "remote-session-1",
    status: "completed",
    workflowName: "remote-workflow",
    workflowId: "remote-workflow",
    nodeExecutions: 2,
    transitions: 1,
    exitCode: 0
  )

  func executeWorkflow(endpoint: String, request: WorkflowRemoteRunRequest) async throws -> WorkflowRemoteRunResult {
    self.endpoint = endpoint
    self.request = request
    return result
  }

  func recordedEndpoint() -> String? {
    endpoint
  }

  func recordedRequest() -> WorkflowRemoteRunRequest? {
    request
  }
}

actor RecordingGeminiAddonHarness {
  private var configurations: [OfficialSDKAdapterConfiguration] = []
  private var inputs: [AdapterExecutionInput] = []

  func makeAdapter(configuration: OfficialSDKAdapterConfiguration) -> any NodeAdapter {
    configurations.append(configuration)
    return RecordingGeminiAddonAdapter(harness: self)
  }

  func record(_ input: AdapterExecutionInput) {
    inputs.append(input)
  }

  func recordedConfigurations() -> [OfficialSDKAdapterConfiguration] {
    configurations
  }

  func recordedInputs() -> [AdapterExecutionInput] {
    inputs
  }
}

struct RecordingGeminiAddonAdapter: NodeAdapter {
  let harness: RecordingGeminiAddonHarness

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    await harness.record(input)
    return AdapterExecutionOutput(
      provider: "official-gemini-sdk",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["text": .string("gemini reply")]
    )
  }
}

actor RecordingSDKAddonHarness {
  private var inputs: [AdapterExecutionInput] = []

  func makeAdapter(provider: String, text: String, usage: AdapterUsage? = nil) -> any NodeAdapter {
    RecordingSDKAddonAdapter(harness: self, provider: provider, text: text, usage: usage)
  }

  func record(_ input: AdapterExecutionInput) {
    inputs.append(input)
  }

  func recordedInputs() -> [AdapterExecutionInput] {
    inputs
  }
}

struct RecordingSDKAddonAdapter: NodeAdapter {
  let harness: RecordingSDKAddonHarness
  let provider: String
  let text: String
  let usage: AdapterUsage?

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    await harness.record(input)
    return AdapterExecutionOutput(
      provider: provider,
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["text": .string(text)],
      usage: usage
    )
  }
}

final class JSONLWriterProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedLines: [String] = []
  private var persistedAtSessionStartValue = false
  private let sessionStore: URL

  init(sessionStore: URL) {
    self.sessionStore = sessionStore
  }

  func record(_ line: String) {
    lock.withLock {
      recordedLines.append(line)
      guard line.contains(#""type":"session_started""#),
        let event = try? JSONDecoder().decode(WorkflowRunEvent.self, from: Data(line.utf8))
      else {
        return
      }
      let session = try? CLIWorkflowSessionStore(rootDirectory: sessionStore.path).load(sessionId: event.sessionId)
      let snapshot = try? SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
      ).load(sessionId: event.sessionId)
      persistedAtSessionStartValue = session != nil && snapshot != nil
    }
  }

  func lines() -> [String] {
    lock.withLock { recordedLines }
  }

  func persistedAtSessionStart() -> Bool {
    lock.withLock { persistedAtSessionStartValue }
  }
}

final class RecordingGraphQLURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var responseQueue: [Data] = []
  private nonisolated(unsafe) static var recordedBodies: [[String: Any]] = []
  private nonisolated(unsafe) static var recordedHeaders: [[String: String]] = []

  static func reset(responses: [String]) {
    lock.withLock {
      responseQueue = responses.map { Data($0.utf8) }
      recordedBodies = []
      recordedHeaders = []
    }
  }

  static func bodies() -> [[String: Any]] {
    lock.withLock { recordedBodies }
  }

  static func headers() -> [[String: String]] {
    lock.withLock { recordedHeaders }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "riela.test"
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let body = request.httpBody ?? Self.data(from: request.httpBodyStream)
    let decoded = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let responseBody: Data = Self.lock.withLock {
      Self.recordedBodies.append(decoded)
      Self.recordedHeaders.append(request.allHTTPHeaderFields ?? [:])
      return Self.responseQueue.isEmpty ? Data(#"{"data":{}}"#.utf8) : Self.responseQueue.removeFirst()
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: responseBody)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func data(from stream: InputStream?) -> Data {
    guard let stream else {
      return Data()
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 {
        break
      }
      data.append(buffer, count: count)
    }
    return data
  }
}

func environmentValue(_ name: String) -> String? {
  getenv(name).map { String(cString: $0) }
}

func setEnvironmentValue(_ name: String, _ value: String?) {
  if let value {
    setenv(name, value, 1)
  } else {
    unsetenv(name)
  }
}

func remoteGraphQLRunResponses(executionId: String = "remote-exec-1", status: String = "paused") -> [String] {
  [
    """
    {
      "data": {
        "executeWorkflow": {
          "workflowExecutionId": "\(executionId)",
          "sessionId": "remote-session-1",
          "status": "\(status)",
          "exitCode": 0
        }
      }
    }
    """,
    """
    {
      "data": {
        "workflowExecution": {
          "session": {
            "sessionId": "remote-session-1",
            "workflowName": "remote-workflow",
            "workflowId": "remote-workflow-id",
            "transitions": [
              { "when": "always" }
            ]
          },
          "nodeExecutions": [
            { "nodeExecId": "node-exec-1" },
            { "nodeExecId": "node-exec-2" }
          ]
        }
      }
    }
    """
  ]
}
