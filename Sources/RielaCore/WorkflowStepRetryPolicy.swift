import Crypto
import Foundation

public enum WorkflowStepRetryJitter: String, Codable, Sendable, Equatable {
  case none, deterministic
}

public struct WorkflowStepRetryPolicy: Codable, Equatable, Sendable {
  public var maxAttempts: Int
  public var initialDelayMs: Int?
  public var multiplier: Double?
  public var maxDelayMs: Int?
  public var jitter: WorkflowStepRetryJitter?

  public init(maxAttempts: Int, initialDelayMs: Int? = nil, multiplier: Double? = nil,
              maxDelayMs: Int? = nil, jitter: WorkflowStepRetryJitter? = nil) {
    self.maxAttempts = maxAttempts
    self.initialDelayMs = initialDelayMs
    self.multiplier = multiplier
    self.maxDelayMs = maxDelayMs
    self.jitter = jitter
  }

  public var effectiveInitialDelayMs: Int { initialDelayMs ?? 1_000 }
  public var effectiveMultiplier: Double { multiplier ?? 2 }
  public var effectiveMaxDelayMs: Int { maxDelayMs ?? 30_000 }
  public var effectiveJitter: WorkflowStepRetryJitter { jitter ?? .none }
}

public protocol WorkflowRetryClock: Sendable {
  func now() -> Date
  func sleep(until: Date) async throws
}

public struct SystemWorkflowRetryClock: WorkflowRetryClock {
  public init() {}
  public func now() -> Date { Date() }
  public func sleep(until: Date) async throws {
    try Task.checkCancellation()
    let seconds = until.timeIntervalSinceNow
    if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
  }
}

public enum StepRetryStopReason: String, Sendable {
  case succeeded, nonRetryable = "non-retryable", outcomeUnknown = "outcome-unknown"
  case retryExhausted = "retry-exhausted", deadlineExhausted = "deadline-exhausted"
  case stepDeadline = "step-deadline", retryAfterExceedsMaxDelay = "retry-after-exceeds-max-delay", cancelled
}

public enum StepTimeoutKind: String, Sendable {
  case attempt, stepDeadline = "step-deadline"
}

public enum StepRetryBackoff {
  public static func delayMs(policy: WorkflowStepRetryPolicy, failedAttempt: Int,
                             sessionId: String, executionId: String) -> Int {
    guard policy.effectiveInitialDelayMs > 0 else { return 0 }
    let base = Double(policy.effectiveInitialDelayMs) * pow(policy.effectiveMultiplier, Double(max(0, failedAttempt - 1)))
    var delay = min(base, Double(policy.effectiveMaxDelayMs))
    if policy.effectiveJitter == .deterministic {
      let digest = SHA256.hash(data: Data("\(sessionId)/\(executionId)/\(failedAttempt)".utf8))
      let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      delay *= 0.5 + 0.5 * (Double(value) / 18_446_744_073_709_551_616.0)
    }
    return Int(delay.rounded(.down))
  }
}

public enum StepRetryDiagnostics {
  public static let backstopGraceMs = 5_000

  public static func suffix(attempts: Int, stopReason: StepRetryStopReason, elapsedMs: Int,
                            timeoutKind: StepTimeoutKind?, effectOutcome: AdapterEffectOutcome?, queueWaitMs: Int?) -> String {
    var text = " [rielaRetry attempts=\(attempts) stopReason=\(stopReason.rawValue) elapsedMs=\(elapsedMs)"
    if let timeoutKind { text += " timeoutKind=\(timeoutKind.rawValue)" }
    if let effectOutcome { text += " effectOutcome=\(effectOutcome.rawValue)" }
    if let queueWaitMs { text += " queueWaitMs=\(queueWaitMs)" }
    return text + "]"
  }
}
