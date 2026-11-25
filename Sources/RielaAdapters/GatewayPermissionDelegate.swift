import ACP
import Foundation
import RielaCore

struct GatewayPermissionDelegate: ACPClientDelegate {
  let handler: AdapterPermissionRequestHandler?

  func sessionUpdate(_ notification: ACPSessionNotification) async {}

  func handleRequest(method: String, params: Data) async throws -> Data {
    guard method == ACPMethod.sessionRequestPermission else { throw ACPError.methodNotFound(method) }
    let request = try ACPConnection.decodeParams(PermissionParams.self, from: params)
    let outcome = if let handler, !Task.isCancelled {
      await handler(request.adapterRequest)
    } else {
      AdapterPermissionOutcome.cancelled
    }
    if !Task.isCancelled, case .selected(let id) = outcome, request.options.contains(where: { $0.optionId == id }) {
      return try ACPConnection.encodeResult(ACPRequestPermissionResponse(outcome: .selected(optionId: id)))
    }
    return try Self.cancelledReply()
  }

  static func cancelledReply() throws -> Data {
    try ACPConnection.encodeResult(ACPRequestPermissionResponse(outcome: .cancelled))
  }

  private struct ToolCallReference: Decodable {
    let toolCallId: String?
    let title: String?
  }

  private struct PermissionParams: Decodable {
    let title: String?
    let toolCall: ToolCallReference?
    let subject: ACPV2PermissionSubject?
    let options: [ACPPermissionOption]

    var adapterRequest: AdapterPermissionRequest {
      var id = toolCall?.toolCallId
      var toolTitle = toolCall?.title
      switch subject {
      case .toolCall(let call):
        id = call.toolCallId
        toolTitle = call.title.value
      case .command(_, _, let callId, _):
        id = callId
      case .other, nil:
        break
      }
      return .init(toolCallId: id, title: title ?? toolTitle, options: options.map {
        .init(optionId: $0.optionId, name: $0.name, kind: $0.kind)
      })
    }
  }
}

/// Cancellation of the prompt does not cancel the separate inbound ACP request.
/// Keep track of replies until ACP has queued them on the wire.
final class GatewayPermissionLifetime: @unchecked Sendable {
  private struct Reply: Decodable {
    let id: ACPRequestID
    let method: String?
  }

  private let lock = NSLock()
  private var closed = false
  private var pending: Set<ACPRequestID> = []
  private var tasks: [ACPRequestID: Task<Data, Error>] = [:]
  private var drained: CheckedContinuation<Void, Never>?

  func install(on connection: ACPConnection, delegate: GatewayPermissionDelegate) async {
    guard delegate.handler != nil else { return }
    await connection.setRawLineObserver { line, outgoing in
      guard outgoing, self.lock.withLock({ !self.pending.isEmpty }),
            let reply = try? JSONDecoder().decode(Reply.self, from: line), reply.method == nil else { return }
      self.sent(reply.id)
    }
    await connection.setOrderedRequestHandler { method, params, id, _ in
      guard method == ACPMethod.sessionRequestPermission else { return .unhandled }
      self.lock.withLock { _ = self.pending.insert(id) }
      return .run {
        let task = self.lock.withLock {
          let active = !self.closed && !Task.isCancelled
          let worker = Task {
            let responder = active ? delegate : GatewayPermissionDelegate(handler: nil)
            return try await responder.handleRequest(method: method, params: params)
          }
          self.tasks[id] = worker
          return worker
        }
        return try await withTaskCancellationHandler {
          let response = try await task.value
          if Task.isCancelled || self.lock.withLock({ self.closed }) {
            return try GatewayPermissionDelegate.cancelledReply()
          }
          return response
        } onCancel: {
          task.cancel()
        }
      }
    }
  }

  func cancel() {
    let tasks = lock.withLock {
      closed = true
      return Array(self.tasks.values)
    }
    for task in tasks { task.cancel() }
  }

  func waitForReplies() async {
    await withCheckedContinuation { continuation in
      let complete = lock.withLock {
        guard !pending.isEmpty else { return true }
        drained = continuation
        return false
      }
      if complete { continuation.resume() }
    }
  }

  private func sent(_ id: ACPRequestID) {
    let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      pending.remove(id)
      tasks[id] = nil
      guard pending.isEmpty else { return nil }
      defer { drained = nil }
      return drained
    }
    waiter?.resume()
  }
}
