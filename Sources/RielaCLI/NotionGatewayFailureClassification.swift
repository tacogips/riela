import Foundation
import GatewaySDKKit
import RielaCore

enum NotionGatewayFailureClassifier {
  private struct Failure {
    var code: String?
    var status: Int?
    var outcome: AdapterEffectOutcome?
    var retryAfter: Int?
  }

  static func classify(stdout: String, isMutation: Bool, message: String) -> AdapterExecutionError {
    let failures = parse(stdout)
    if failures.contains(where: { $0.outcome == .unknown }) {
      return AdapterExecutionError(.providerError, message, isRetryable: false, effectOutcome: .unknown)
    }
    let failure = failures.first
    let retryAfter = failure?.retryAfter.map { Duration.seconds($0) }
    if isMutation {
      guard let outcome = failure?.outcome else {
        return AdapterExecutionError(.providerError, message, isRetryable: false, effectOutcome: .unknown)
      }
      let retryable = outcome == .rejected && (failure?.status == 429 || failure?.status == 409 ||
        failure?.code == "rate_limited" || failure?.code == "conflict_error")
      return AdapterExecutionError(.providerError, message, isRetryable: retryable,
                                   retryAfter: retryAfter, effectOutcome: outcome)
    }
    let status = failure?.status ?? 0
    let retryable = [429, 409, 408].contains(status) || (500...599).contains(status) ||
      failure?.code == "TRANSPORT" || failure?.code == "INVALID_RESPONSE"
    return AdapterExecutionError(.providerError, message, isRetryable: retryable, retryAfter: retryAfter)
  }

  static func isMutation(tier: String, operationKind: GatewayDefinitionKind?, isJSONOperationMode: Bool,
                         document: String) -> Bool {
    if tier == "reader" { return false }
    if isJSONOperationMode { return operationKind != .query }
    var lines = document.split(separator: "\n", omittingEmptySubsequences: false)[...]
    while let line = lines.first, line.trimmingCharacters(in: .whitespaces).isEmpty ||
      line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { lines = lines.dropFirst() }
    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return !(body.hasPrefix("query") || body.hasPrefix("{"))
  }

  private static func parse(_ stdout: String) -> [Failure] {
    guard let root = try? JSONDecoder().decode(JSONObject.self, from: Data(stdout.utf8)),
          case let .array(errors)? = root["errors"] else { return [] }
    return errors.prefix(16).compactMap { value in
      guard case let .object(error) = value else { return nil }
      var result = Failure()
      if case let .string(code)? = error["code"] { result.code = code }
      if case let .object(ext)? = error["extensions"], case let .integer(status)? = ext["httpStatus"],
         (100...599).contains(status) { result.status = Int(status) }
      if case let .string(message)? = error["message"],
         let start = message.range(of: "[notionDiagnostics "),
         let end = message[start.upperBound...].firstIndex(of: "]") {
        for token in message[start.upperBound..<end].split(separator: " ") {
          let pair = token.split(separator: "=", maxSplits: 1)
          guard pair.count == 2 else { continue }
          if pair[0] == "mutationOutcome" { result.outcome = AdapterEffectOutcome(rawValue: String(pair[1])) }
          if pair[0] == "retryAfterSeconds", let seconds = Int(pair[1]), (0...86400).contains(seconds) {
            result.retryAfter = seconds
          }
        }
      }
      return result
    }
  }
}

private final class NotionStarted: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func mark() { lock.lock(); value = true; lock.unlock() }
  func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

func notionRunWithDeadline(deadline: Date?, addonName: String, isMutation: Bool,
                           operation: @escaping @Sendable () async throws -> String) async throws -> String {
  let started = NotionStarted()
  do {
    return try await localGatewayRunWithDeadline(deadline: deadline, addonName: addonName, providerName: "notion-gateway") {
      started.mark()
      return try await operation()
    }
  } catch let error as AdapterExecutionError where error.code == .timeout {
    let didStart = started.get()
    throw AdapterExecutionError(error.code, error.message, isRetryable: !didStart || !isMutation,
                                effectOutcome: !didStart ? .notDispatched : (isMutation ? .unknown : nil))
  }
}
