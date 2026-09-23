import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaCore

/// Controlled only by explicit test-process environment. This is deliberately
/// unavailable to normal CLI input, so crash-matrix tests can stop the real
/// product runner without adding a user-facing failure or permission surface.
private let nestedRecoveryTestEnabledKey = "RIELA_ENABLE_TEST_FAILPOINTS"
private let nestedRecoveryCheckpointKey = "RIELA_TEST_NESTED_RECOVERY_CHECKPOINT"

func workflowRunNestedRecoveryCheckpointer(
  options _: WorkflowRunOptions
) throws -> (any NestedRecoveryCheckpointing)? {
  let environment = ProcessInfo.processInfo.environment
  guard environment[nestedRecoveryTestEnabledKey] == "1",
        let rawCheckpoint = environment[nestedRecoveryCheckpointKey] else {
    return nil
  }
  guard let checkpoint = NestedRecoveryCheckpoint(rawValue: rawCheckpoint) else {
    throw CLIUsageError("unsupported nested recovery checkpoint: \(rawCheckpoint)")
  }
  return WorkflowRunNestedRecoveryCheckpointer(target: checkpoint)
}

private struct WorkflowRunNestedRecoveryCheckpointer: NestedRecoveryCheckpointing {
  let target: NestedRecoveryCheckpoint

  func reached(_ checkpoint: NestedRecoveryCheckpoint) async throws {
    guard checkpoint == target else { return }
    // Do not throw here: normal error unwinding finalizes CLI state and is not
    // evidence for process-death recovery. SIGKILL is intentionally
    // uncatchable, so the next invocation must reconstruct solely from the
    // canonical SQLite journal. This seam is gated above by an explicit
    // test-only environment flag and has no CLI argument surface.
    _ = kill(getpid(), SIGKILL)
    fatalError("SIGKILL did not terminate the test process")
  }
}
