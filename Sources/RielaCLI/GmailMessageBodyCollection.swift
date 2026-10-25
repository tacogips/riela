import Foundation
import RielaAddonSupport
import RielaCore

/// Exact-body recovery has its own identity and never advances a listing cursor.
struct GmailMessageBodyOptions {
  let account: String
  let mailboxHash: String
  let messageIDs: [String]
  let maximum: Int
  let interval: Double
  let providerMetadata: Bool

  init(_ value: JSONObject) throws {
    guard Set(value.keys).isSubset(of: ["mode", "accountId", "expectedMailboxHash", "messageIds",
      "maxMessages", "minRequestIntervalSeconds", "providerBodyMetadata"]),
      value["mode"] == .string("message-bodies"),
      case let .string(account)? = value["accountId"], !account.isEmpty, account.utf8.count <= 256,
      case let .string(hash)? = value["expectedMailboxHash"],
      hash.range(of: #"^[0-9a-f]{24}$"#, options: .regularExpression) != nil,
      case let .array(ids)? = value["messageIds"], (1...128).contains(ids.count),
      case let .integer(maximum) = value["maxMessages"] ?? .integer(16), (1...128).contains(maximum),
      case let .bool(metadata) = value["providerBodyMetadata"] ?? .bool(false)
    else { throw gmailCollectionInvalid() }
    let messages = ids.compactMap { nonEmptyString($0) }
    guard messages.count == ids.count, Set(messages).count == messages.count,
      messages.allSatisfy({ $0.utf8.count <= 256 && $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil })
    else { throw gmailCollectionInvalid() }
    let interval: Double
    switch value["minRequestIntervalSeconds"] ?? .number(2.5) {
    case let .integer(number): interval = Double(number)
    case let .number(number): interval = number
    default: throw gmailCollectionInvalid()
    }
    guard interval.isFinite, (0...60).contains(interval) else { throw gmailCollectionInvalid() }
    self.account = account; self.mailboxHash = hash; self.messageIDs = messages
    self.maximum = Int(maximum); self.interval = interval; self.providerMetadata = metadata
  }
}

struct GmailMessageBodyCollector {
  let options: GmailMessageBodyOptions
  var deadline: Date?
  var outputByteBudget = 8_000_000
  var clock: () -> Date = { Date() }
  var wait: (Double) async throws -> Void = { if $0 > 0 { try await Task.sleep(for: .seconds($0)) } }

  func collect(fetch: (String, JSONObject, [String]) async throws -> JSONObject) async throws -> JSONObject {
    guard outputByteBudget >= 65_536 else { throw gmailCollectionInvalid() }
    var requests = 0
    func read(_ operation: String, _ arguments: JSONObject, _ selection: [String]) async throws -> JSONObject? {
      try Task.checkCancellation()
      if let deadline, deadline.timeIntervalSince(clock()) <= (requests > 0 ? options.interval : 0) {
        return nil
      }
      if requests > 0 { try await wait(options.interval) }
      try Task.checkCancellation()
      if let deadline, clock() >= deadline {
        return nil
      }
      requests += 1
      let value = try await fetch(operation, arguments, selection)
      try Task.checkCancellation()
      return value
    }
    guard let profile = try await read("profile", ["accountId": .string(options.account)], ["emailAddress"]) else {
      throw AdapterExecutionError(.timeout, "Gmail body collection execution budget exhausted")
    }
    guard let email = nonEmptyString(profile["emailAddress"]),
      String(JSONCanonical.sha256Hex(Data(email.utf8)).prefix(24)) == options.mailboxHash
    else { throw gmailCollectionInvalid() }
    var bodies: [JSONValue] = [], failures: [JSONValue] = []
    var bodyBytes = 2 // JSON array brackets; count each body only once.
    var resolved = Set<String>()
    let selection = ["accountId", "messageId", "complete", "byteCount", "parts.partId", "parts.mimeType",
      "parts.charset", "parts.dataBase64", "parts.byteCount", "parts.sha256"]
      + (options.providerMetadata ? ["representationScope", "parts.providerDeclaredByteCount", "parts.sizeStatus"] : [])
    for id in options.messageIDs.prefix(options.maximum) {
      try Task.checkCancellation()
      if let deadline, deadline.timeIntervalSince(clock()) <= options.interval { break }
      do {
        guard let body = try await read("messageBodyBytes", ["accountId": .string(options.account),
          "messageId": .string(id), "maxBytes": .integer(2_097_152)], selection) else { break }
        guard body["accountId"] == .string(options.account), body["messageId"] == .string(id),
          body["complete"] == .bool(true), case let .integer(bytes)? = body["byteCount"],
          (0...2_097_152).contains(bytes), case .array? = body["parts"] else { throw gmailCollectionInvalid() }
        // Keep the accepted prefix even when the next body exceeds this frame.
        // That ID stays pending; no downstream receipt is fabricated.
        let candidateBytes = try JSONEncoder().encode(body).count + (bodies.isEmpty ? 0 : 1)
        if bodyBytes + candidateBytes + 65_536 > outputByteBudget {
          if !bodies.isEmpty { break }
          failures.append(.object(["messageId": .string(id), "code": .string("body-frame-too-large")]))
          resolved.insert(id)
          continue
        }
        bodyBytes += candidateBytes
        bodies.append(.object(body)); resolved.insert(id)
      } catch is CancellationError { throw CancellationError() } catch {
        try Task.checkCancellation()
        failures.append(.object(["messageId": .string(id), "code": .string("acquisition-unavailable")]))
        resolved.insert(id)
      }
    }
    try Task.checkCancellation()
    let pending = options.messageIDs.filter { !resolved.contains($0) }
    let result: JSONObject = ["bodies": .array(bodies), "failures": .array(failures),
      "pendingMessageIds": .array(pending.map(JSONValue.string)), "complete": .bool(pending.isEmpty),
      "attemptCount": .integer(Int64(requests - 1)), "requestCount": .integer(Int64(requests))]
    guard try JSONEncoder().encode(result).count <= outputByteBudget else { throw gmailCollectionInvalid() }
    return result
  }
}
