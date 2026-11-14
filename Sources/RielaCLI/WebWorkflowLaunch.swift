import Foundation
import RielaAppSupport
import RielaCore
import RielaWorkflowRegistry

/// Synchronous event sink matches the CLI writer contract and preserves event
/// order without scheduling a separate Task for every record.
public final class WebWorkflowLaunch: @unchecked Sendable {
  enum State: String { case running, completed, failed }
  public let id = UUID().uuidString.lowercased()
  public let profile: String
  public let createdAt = Date()
  private let lock = NSLock()
  private var state = State.running
  private var sessionId: String?
  private var error: String?

  init(profile: String) { self.profile = profile }

  func append(_ line: String) {
    guard let data = line.data(using: .utf8),
          let event = try? JSONDecoder().decode(JSONObject.self, from: data),
          case let .string(id) = event["sessionId"] else { return }
    lock.lock()
    if sessionId == nil { sessionId = id }
    lock.unlock()
  }

  func finish(_ result: CLICommandResult) {
    lock.lock()
    state = result.exitCode == .success ? .completed : .failed
    if state == .failed {
      error = "Workflow execution failed. Inspect the recorded attempt for details."
      if sessionId == nil {
        error = WorkflowWebProjectionPolicy().safeSummary(result.stderr.isEmpty ? result.stdout : result.stderr)
      }
    }
    lock.unlock()
  }

  public var snapshot: JSONObject {
    lock.lock()
    defer { lock.unlock() }
    return ["id": .string(id), "status": .string(state.rawValue),
      "sessionId": sessionId.map(JSONValue.string) ?? .null,
      "error": error.map(JSONValue.string) ?? .null]
  }
}

struct EditorPreparedBundleResolver: WorkflowBundleResolving {
  let bundle: ResolvedWorkflowBundle
  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    guard options.workflowName == bundle.workflow.workflowId else {
      return try FileSystemWorkflowBundleResolver().resolve(options)
    }
    return bundle
  }
}
