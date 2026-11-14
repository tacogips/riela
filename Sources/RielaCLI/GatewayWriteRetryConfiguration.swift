import Foundation
import RielaAddonSupport
import RielaCore

/// Explicit add-on configuration only; ambient retry variables are never copied.
func gatewayWriteRetryEnvironment(
  _ input: WorkflowAddonExecutionInput,
  prefix: String
) throws -> [String: String] {
  guard let value = input.addon.config?["writeRetry"] else { return [:] }
  let rendered = try renderAddonConfig(value, variables: addonVariables(for: input))
  guard case let .object(options) = rendered,
        Set(options.keys).isSubset(of: ["initialWaitSeconds", "maxRetries"]) else {
    throw AdapterExecutionError(.invalidInput, "config.writeRetry must be an object containing only initialWaitSeconds and maxRetries")
  }
  func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
    guard let value = options[name] else { return fallback }
    let result: Int?
    switch value {
    case let .integer(number): result = Int(exactly: number)
    case let .number(number): result = number.isFinite ? Int(exactly: number) : nil
    default: result = nil
    }
    guard let result, range.contains(result) else {
      throw AdapterExecutionError(.invalidInput, "config.writeRetry.\(name) must be an integer in \(range.lowerBound)...\(range.upperBound)")
    }
    return result
  }
  return [
    prefix + "WRITE_RETRY_INITIAL_WAIT_SECONDS": String(try integer("initialWaitSeconds", default: 2, range: 1...60)),
    prefix + "WRITE_RETRY_MAX_RETRIES": String(try integer("maxRetries", default: 3, range: 0...5))
  ]
}
