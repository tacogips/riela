import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore

/// Injectable HTTP edge used by the durable delivery worker.  Tests supply a
/// stub; production composition supplies URLSession and never obtains endpoint
/// or credentials from a model or chat message.
protocol SpecialistHTTPTransport: Sendable {
  func send(url: URL, method: String, headers: [String: String], body: Data) async throws -> (status: Int, body: Data)
  func sendWithHeaders(url: URL, method: String, headers: [String: String], body: Data) async throws -> SpecialistHTTPResponse
}

struct SpecialistHTTPResponse: Sendable {
  let status: Int
  let body: Data
  let headers: [String: String]
}

extension SpecialistHTTPTransport {
  func sendWithHeaders(url: URL, method: String, headers: [String: String], body: Data) async throws -> SpecialistHTTPResponse {
    let response = try await send(url: url, method: method, headers: headers, body: body)
    return SpecialistHTTPResponse(status: response.status, body: response.body, headers: [:])
  }
}

struct URLSessionSpecialistHTTPTransport: SpecialistHTTPTransport {
  func send(url: URL, method: String, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (http.statusCode, data)
  }

  func sendWithHeaders(url: URL, method: String, headers: [String: String], body: Data) async throws -> SpecialistHTTPResponse {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var responseHeaders: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      guard let key = key as? String else { continue }
      responseHeaders[key.lowercased()] = String(describing: value)
    }
    return SpecialistHTTPResponse(status: http.statusCode, body: data, headers: responseHeaders)
  }
}

enum SpecialistRemoteDeliveryError: Error, Sendable {
  case retryable(retryAfter: TimeInterval? = nil)
  case permanent
  case uncertain
}

struct SpecialistMatrixDeliveryAdapter: Sendable {
  let homeserver: URL
  let accessToken: String
  let transport: any SpecialistHTTPTransport

  func deliver(_ event: SpecialistOutboxEvent, roomId: String) async throws -> String {
    // The durable outbox ID is Matrix's transaction id, preserving idempotency
    // across retry and process restart.
    guard homeserver.scheme?.lowercased() == "https", homeserver.host != nil,
          isSafePathSegment(roomId), isSafePathSegment(event.eventId) else {
      throw SpecialistRemoteDeliveryError.permanent
    }
    guard var components = URLComponents(url: homeserver, resolvingAgainstBaseURL: false) else {
      throw SpecialistRemoteDeliveryError.permanent
    }
    let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.percentEncodedPath = "/" + ([base, "_matrix", "client", "v3", "rooms", encodedPathSegment(roomId), "send", "m.room.message", encodedPathSegment(event.eventId)]
      .filter { !$0.isEmpty }
      .joined(separator: "/"))
    guard let url = components.url else { throw SpecialistRemoteDeliveryError.permanent }
    var content: [String: Any] = ["msgtype": "m.text", "body": event.payload]
    if let threadId = event.recipient?.threadId {
      content["m.relates_to"] = ["rel_type": "m.thread", "event_id": threadId]
    }
    let payload = try JSONSerialization.data(withJSONObject: content)
    let response: SpecialistHTTPResponse
    do {
      response = try await transport.sendWithHeaders(url: url, method: "PUT", headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"], body: payload)
    } catch {
      throw SpecialistRemoteDeliveryError.uncertain
    }
    switch response.status {
    case 200 ... 299:
      guard let payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let eventId = payload["event_id"] as? String,
            eventId.hasPrefix("$"), eventId.count > 1,
            !eventId.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
        throw SpecialistRemoteDeliveryError.uncertain
      }
      return eventId
    case 408, 425, 429, 500 ... 599: throw SpecialistRemoteDeliveryError.retryable(retryAfter: retryAfter(response.headers))
    default: throw SpecialistRemoteDeliveryError.permanent
    }
  }

  private func isSafePathSegment(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
  }

  private func encodedPathSegment(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }
}

/// Authenticated Matrix intake. Provider envelope identifiers remain opaque;
/// only the configured account token authorizes the `/sync` request and the
/// event sender becomes the task principal. Chat JSON can never nominate an
/// account, actor, room, workflow, or tracker target.
struct SpecialistMatrixIntakeAdapter: Sendable {
  let homeserver: URL
  let accessToken: String
  let accountId: String
  let localUserId: String
  let transport: any SpecialistHTTPTransport
  var allowedRoomIDs: Set<String>?

  func poll(since: String? = nil) async throws -> (nextBatch: String?, events: [SpecialistMatrixInboundEvent]) {
    guard homeserver.scheme?.lowercased() == "https", homeserver.host != nil,
          !accessToken.isEmpty, !accountId.isEmpty, !localUserId.isEmpty else {
      throw SpecialistRemoteDeliveryError.permanent
    }
    guard var components = URLComponents(url: homeserver, resolvingAgainstBaseURL: false) else {
      throw SpecialistRemoteDeliveryError.permanent
    }
    let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.percentEncodedPath = "/" + ([base, "_matrix", "client", "v3", "sync"].filter { !$0.isEmpty }.joined(separator: "/"))
    if let since, !since.isEmpty { components.queryItems = [URLQueryItem(name: "since", value: since)] }
    guard let url = components.url else { throw SpecialistRemoteDeliveryError.permanent }
    let reply: (status: Int, body: Data)
    do {
      reply = try await transport.send(url: url, method: "GET", headers: ["Authorization": "Bearer \(accessToken)"], body: Data())
    } catch {
      throw SpecialistRemoteDeliveryError.uncertain
    }
    switch reply.status {
    case 200 ... 299: break
    case 408, 425, 429, 500 ... 599: throw SpecialistRemoteDeliveryError.retryable()
    default: throw SpecialistRemoteDeliveryError.permanent
    }
    guard let document = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any] else {
      throw SpecialistRemoteDeliveryError.uncertain
    }
    let nextBatch = document["next_batch"] as? String
    let joined = ((document["rooms"] as? [String: Any])?["join"] as? [String: Any]) ?? [:]
    var events: [SpecialistMatrixInboundEvent] = []
    for (roomId, value) in joined.sorted(by: { $0.key < $1.key }) {
      guard allowedRoomIDs?.contains(roomId) ?? true else { continue }
      guard let room = value as? [String: Any],
            let timeline = room["timeline"] as? [String: Any],
            let records = timeline["events"] as? [[String: Any]] else { continue }
      for record in records {
        guard record["type"] as? String == "m.room.message",
              let eventId = record["event_id"] as? String,
              let sender = record["sender"] as? String,
              sender != localUserId,
              let content = record["content"] as? [String: Any],
              let body = content["body"] as? String,
              !body.isEmpty else { continue }
        let relation = content["m.relates_to"] as? [String: Any]
        events.append(SpecialistMatrixInboundEvent(
          sourceEventId: eventId, principal: SpecialistPrincipal(
            accountId: accountId, actorId: sender, roomId: roomId,
            threadId: relation?["rel_type"] as? String == "m.thread" ? relation?["event_id"] as? String : nil
          ), body: String(body.prefix(32_768))
        ))
      }
    }
    return (nextBatch, events)
  }
}

struct SpecialistMatrixInboundEvent: Sendable {
  let sourceEventId: String
  let principal: SpecialistPrincipal
  let body: String
}

/// The tracker never receives a caller-chosen endpoint or bearer token. The
/// concrete composition invokes the linked writer-tier wrike-gateway, whose
/// capability registry rejects administrative and delete operations.
protocol SpecialistWrikeGateway: Sendable {
  func deliver(_ event: SpecialistOutboxEvent, trackerTaskId: String?) async throws -> String
  func reconcile(_ event: SpecialistOutboxEvent, trackerTaskId: String?) async throws -> SpecialistWrikeReconciliation
}

enum SpecialistWrikeReconciliation: Equatable, Sendable {
  /// A reader-tier lookup found the stable outbox correlation marker.
  case delivered(String)
  /// A negative lookup is not proof that an eventually-consistent provider
  /// rejected the write, so delivery remains explicitly uncertain.
  case notFound
  case conflicting
}

extension SpecialistWrikeGateway {
  func reconcile(_: SpecialistOutboxEvent, trackerTaskId _: String?) async throws -> SpecialistWrikeReconciliation {
    .notFound
  }
}

struct SpecialistWrikeDeliveryAdapter: Sendable {
  let gateway: any SpecialistWrikeGateway

  func deliver(_ event: SpecialistOutboxEvent, trackerTaskId: String? = nil) async throws -> String {
    try await gateway.deliver(event, trackerTaskId: trackerTaskId)
  }

  func reconcile(_ event: SpecialistOutboxEvent, trackerTaskId: String? = nil) async throws -> SpecialistWrikeReconciliation {
    try await gateway.reconcile(event, trackerTaskId: trackerTaskId)
  }
}

struct SpecialistOutboxDeliveryWorker: Sendable {
  let store: SpecialistSupervisorStore
  let matrix: SpecialistMatrixDeliveryAdapter?
  let matrixRoomID: String?
  let wrike: SpecialistWrikeDeliveryAdapter?
  var matrixAccountID: String?

  func deliverPending(limit: Int = 100, now: Date = Date()) async -> [SpecialistDeliveryReceipt] {
    var receipts: [SpecialistDeliveryReceipt] = []
    for event in (try? store.pendingOutboxEvents(limit: limit, now: now)) ?? [] {
      guard let lease = try? store.beginDelivery(eventId: event.eventId) else { continue }
      do {
        let receipt: String
        switch event.destination {
        case "chat":
          guard let matrix, let matrixRoomID, let recipient = event.recipient,
                recipient.roomId == matrixRoomID,
                matrixAccountID == nil || matrixAccountID == recipient.accountId else {
            throw SpecialistRemoteDeliveryError.permanent
          }
          receipt = try await matrix.deliver(event, roomId: matrixRoomID)
        case "tracker":
          guard let wrike else { throw SpecialistRemoteDeliveryError.permanent }
          let trackerTaskId: String?
          if let taskId = event.taskId {
            trackerTaskId = try store.trackerTaskId(taskId: taskId)
          } else {
            trackerTaskId = nil
          }
          receipt = try await wrike.deliver(event, trackerTaskId: trackerTaskId)
          if event.operation == "ownership", let taskId = event.taskId {
            _ = try store.recordTrackerTask(taskId: taskId, remoteTaskId: receipt)
          }
          if let taskId = event.taskId {
            _ = try store.recordTrackerObservation(taskId: taskId)
          }
        default: throw SpecialistRemoteDeliveryError.permanent
        }
        if let completed = try? store.completeDelivery(lease, state: .delivered, remoteReceiptId: receipt) { receipts.append(completed) }
      } catch let SpecialistRemoteDeliveryError.retryable(retryAfter) {
        if let completed = try? store.completeDelivery(lease, state: .retryableFailure, retryAfter: retryAfter) { receipts.append(completed) }
      } catch SpecialistRemoteDeliveryError.uncertain {
        // A remote write may have committed after a response loss. Query only
        // through the configured reader boundary before marking this durable
        // event uncertain; never issue a blind replacement write.
        if event.destination == "tracker", let wrike {
          let taskId = event.taskId.flatMap { try? store.trackerTaskId(taskId: $0) }
          if case let .delivered(remoteReceipt) = (try? await wrike.reconcile(event, trackerTaskId: taskId)),
             bindRecoveredTracker(event, remoteReceipt: remoteReceipt) {
            if let completed = try? store.completeDelivery(lease, state: .delivered, remoteReceiptId: remoteReceipt) { receipts.append(completed) }
            continue
          }
        }
        if let completed = try? store.completeDelivery(lease, state: .uncertain) { receipts.append(completed) }
      } catch SpecialistRemoteDeliveryError.permanent {
        if let completed = try? store.completeDelivery(lease, state: .permanentFailure) { receipts.append(completed) }
      } catch {
        if let completed = try? store.completeDelivery(lease, state: .uncertain) { receipts.append(completed) }
      }
    }
    return receipts
  }

  /// Repair only an already-uncertain tracker event and only from a matching
  /// reader-tier correlation receipt.  Negative and conflicting lookups retain
  /// uncertainty; they never schedule or authorize a replacement remote write.
  func reconcileUncertain(limit: Int = 100) async -> [SpecialistDeliveryReceipt] {
    guard let wrike else { return [] }
    var receipts: [SpecialistDeliveryReceipt] = []
    for event in (try? store.uncertainOutboxEvents(limit: limit)) ?? [] where event.destination == "tracker" {
      let trackerTaskId = event.taskId.flatMap { try? store.trackerTaskId(taskId: $0) }
      guard case let .delivered(remoteReceipt) = (try? await wrike.reconcile(event, trackerTaskId: trackerTaskId)) else {
        continue
      }
      if bindRecoveredTracker(event, remoteReceipt: remoteReceipt),
         let settled = try? store.reconcileDelivery(eventId: event.eventId, remoteReceiptId: remoteReceipt) {
        receipts.append(settled)
      }
    }
    return receipts
  }

  private func bindRecoveredTracker(_ event: SpecialistOutboxEvent, remoteReceipt: String) -> Bool {
    guard event.operation == "ownership" else { return true }
    guard let taskId = event.taskId else { return false }
    do {
      _ = try store.recordTrackerTask(taskId: taskId, remoteTaskId: remoteReceipt)
      return true
    } catch {
      // Preserve uncertainty if a conflicting mapping exists. Never settle
      // delivery while later lifecycle events cannot address the same task.
      return false
    }
  }
}

private func retryAfter(_ headers: [String: String]) -> TimeInterval? {
  let value = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value
  guard let value, let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)),
        seconds.isFinite, seconds >= 0 else {
    return nil
  }
  return min(seconds, 60)
}
