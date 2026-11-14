import AgentGateway
import AgentGatewayAppCore

/// The ACP transport owns requests, not the executor tasks launched by the
/// gateway agent. Retain the turn's task separately so a failed/disconnected
/// client cannot leave an executor running after Riela has returned the node.
actor GatewayTurnExecutor: GatewayExecuting {
  private let base: any GatewayExecuting
  private var task: Task<GatewayExecuteResult, Error>?
  private var isClosed = false

  init(base: any GatewayExecuting) {
    self.base = base
  }

  func execute(_ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter) async throws -> GatewayExecuteResult {
    guard !isClosed, task == nil else { throw CancellationError() }
    let base = base
    let execution = Task { try await base.execute(params, emit: emit) }
    task = execution
    return try await withTaskCancellationHandler {
      try await execution.value
    } onCancel: {
      execution.cancel()
    }
  }

  func finish() async {
    isClosed = true
    let execution = task
    execution?.cancel()
    _ = await execution?.result
    task = nil
  }
}

/// Async resource cleanup must complete on both return and throw. In
/// particular, `defer { Task { ... } }` is not an ownership boundary.
func withGatewayTurnLifetime<Value: Sendable>(
  cleanup: () async -> Void,
  operation: () async throws -> Value
) async throws -> Value {
  let result: Result<Value, Error>
  do {
    result = .success(try await operation())
  } catch {
    result = .failure(error)
  }
  await cleanup()
  return try result.get()
}

/// This is a model-visible execution contract, not a shell parser or a
/// sandbox. Vendor CLI tool execution still needs upstream process ownership.
let gatewayForegroundExecutionInstructions = """
Riela owns this agent turn. Run verification and shell commands in the foreground.
Do not launch detached/background commands using &, nohup, disown, setsid, or daemonization.
If a tool yields a running session, retain its handle and poll it through terminal exit; do not return the node while it is running.
Keep the final exit status and complete log path in verification evidence. An incomplete log is not a passing check.
Long-lived work must use an explicitly owned Riela workflow/service lifecycle, not a shell orphan.
"""
