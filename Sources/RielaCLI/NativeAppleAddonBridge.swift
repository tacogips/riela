import Foundation
import RielaCore

struct NativeAppleAddonBridge: Sendable {
  var channel: NativeAddonBridgeChannel
  var capability: AppleGatewayContainerCapability
  var environment: [String: String]
  var deadline: Date
  var runner: AppleGatewayRunner

  func serve() async throws {
    var handled = Set<UUID>()
    var executedCalls = 0
    var approvedDownloadKeys = Set<String>()
    while !Task.isCancelled, Date() < deadline {
      for id in try channel.requests() where !handled.contains(id) {
        guard handled.count < 128 else { throw AdapterExecutionError(.policyBlocked, "native bridge request limit exceeded") }
        handled.insert(id)
        let reply: NativeAddonBridgeReply
        do {
          let request = try channel.request(id)
          if request.arguments.first == "file", capability.canDownloadReferencedFiles {
            try capability.validateDependentDownload(request.arguments, approvedKeys: approvedDownloadKeys)
          } else {
            try capability.validate(arguments: request.arguments)
          }
          // A mutating built-in grants one backend operation, not repeated
          // side effects under fresh guest-generated correlation identifiers.
          guard executedCalls < capability.maximumNativeCalls else {
            throw AdapterExecutionError(.policyBlocked, "native bridge operation budget exceeded")
          }
          let effectiveDeadline = min(deadline, request.deadline)
          guard Date() < effectiveDeadline else { throw AdapterExecutionError(.timeout, "native bridge request expired") }
          executedCalls += 1
          let output = try capability.withNativeArguments(request.arguments, deadline: effectiveDeadline, environment: environment) { arguments in
            try runner(arguments, environment, effectiveDeadline)
          }
          if output.terminationStatus == 0 { approvedDownloadKeys.formUnion(downloadKeys(output.stdout)) }
          reply = .init(output: output)
        } catch let error as AdapterExecutionError {
          reply = .init(failure: .init(error))
        } catch {
          reply = .init(failure: .init(AdapterExecutionError(.providerError, "native bridge request failed")))
        }
        try channel.reply(reply, to: id)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    try Task.checkCancellation()
    throw AdapterExecutionError(.timeout, "native bridge execution exceeded its deadline")
  }

  private func downloadKeys(_ stdout: String) -> Set<String> {
    guard let data = stdout.data(using: .utf8), case let .object(root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
          let value = root["data"] else { return [] }
    if case let .array(errors)? = root["errors"], !errors.isEmpty { return [] }
    return keys(in: value)
  }

  private func keys(in value: JSONValue) -> Set<String> {
    switch value {
    case let .object(object):
      var result = Set<String>()
      if case let .string(key)? = object["downloadKey"], !key.isEmpty { result.insert(key) }
      for child in object.values { result.formUnion(keys(in: child)) }
      return result
    case let .array(array): return array.reduce(into: Set<String>()) { $0.formUnion(keys(in: $1)) }
    default: return []
    }
  }
}
