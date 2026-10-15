import Foundation
import RielaCore
import RielaKaibaSupport

struct NativeKaibaAddonBridge: Sendable {
  static let operation = "kaiba-http"
  var channel: NativeAddonBridgeChannel
  var transport: KaibaContainerHostTransport
  var deadline: Date

  func serve() async throws {
    var handled = Set<UUID>()
    while !Task.isCancelled, Date() < deadline {
      for id in try channel.requests() where !handled.contains(id) {
        guard handled.count < 128 else { throw AdapterExecutionError(.policyBlocked, "Kaiba bridge request limit exceeded") }
        handled.insert(id)
        let reply: NativeAddonBridgeReply
        do {
          let request = try channel.request(id)
          guard request.arguments.count == 2, request.arguments[0] == Self.operation else {
            throw AdapterExecutionError(.policyBlocked, "Kaiba bridge accepts only the captured GraphQL transport")
          }
          let output = try await transport.send(request.arguments[1], deadline: min(deadline, request.deadline))
          reply = .init(output: .init(stdout: output, stderr: ""))
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as AdapterExecutionError {
          reply = .init(failure: .init(error))
        } catch {
          reply = .init(failure: .init(.init(.providerError, "Kaiba host transport failed")))
        }
        try channel.reply(reply, to: id)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    try Task.checkCancellation()
    throw AdapterExecutionError(.timeout, "Kaiba bridge exceeded its execution deadline")
  }
}
