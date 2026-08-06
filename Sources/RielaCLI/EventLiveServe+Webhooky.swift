import Crypto
import Foundation
import RielaCore
import RielaEvents
import RielaObservability
import WebHooky

/// Streams webhook records from a web-hooky server over its `/_ws/{fetchUuid}`
/// WebSocket surface so persisted vendor deliveries (Wrike, GitHub, ...) can
/// trigger workflows in near real time.
protocol WebhookyRecordStreaming: Sendable {
  func stream(
    source: WebhookyStreamSource,
    environment: [String: String]
  ) throws -> AsyncThrowingStream<WebhookRecord, Error>
}

struct SDKWebhookyRecordStreamer: WebhookyRecordStreaming {
  func stream(
    source: WebhookyStreamSource,
    environment: [String: String]
  ) throws -> AsyncThrowingStream<WebhookRecord, Error> {
    let resolved = try source.resolvedConnection(environment: environment)
    let client = try WebHookyFetchClient(config: FetchClientConfig(
      baseURL: resolved.baseURL,
      apiKey: resolved.apiKey,
      apiSecret: resolved.apiSecret
    ))
    return client.stream(
      fetchUUID: resolved.fetchUUID,
      options: StreamOptions(reconnect: true)
    )
  }
}

extension DefaultEventLiveServer {
  func startWebhookyStreams(
    sources: [WebhookyStreamSource],
    buffer: WebhookyRecordBuffer,
    eventRoot: URL
  ) -> [Task<Void, Never>] {
    sources.map { source in
      Task { [webhookyStreamer, telemetry] in
        while !Task.isCancelled {
          do {
            let stream = try webhookyStreamer.stream(
              source: source,
              environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
            )
            for try await record in stream {
              await buffer.append(sourceId: source.id, record: record)
            }
            // A cleanly finished stream (for example a fake in tests, or a
            // server-side normal close without reconnect) ends the task.
            await buffer.markFinished(sourceId: source.id)
            return
          } catch {
            try? writeServeRecord(
              eventRoot: eventRoot,
              status: "ready",
              detail: appleGatewayCompactText(String(describing: error)),
              lastIgnoredReason: "webhooky-stream-failed",
              lastEnvelopeSourceId: source.id,
              lastDiagnosticCodes: "event_source_poll_failed"
            )
            await telemetry.recordLog(RielaTelemetryLog(
              name: "riela.events.source.poll.failed",
              attributes: [
                "runtime.surface": "events-serve",
                "event.source.id": source.id,
                "event.source.kind": "webhooky"
              ]
            ))
            try? await Task.sleep(nanoseconds: 5_000_000_000)
          }
        }
      }
    }
  }

  func dispatchWebhookyRecord(
    source: WebhookyStreamSource,
    record: WebhookRecord,
    config: EventLiveConfig,
    eventRoot: URL,
    parsed: ParsedParityOptions
  ) async throws -> Int {
    if record.fetched && !source.includeFetched {
      return 0
    }
    let payload = webhookyJSONValue(record.payload)
    let payloadDigest = webhookyPayloadDigest(payload, t: record.t)
    let envelope = ExternalEventEnvelope(
      sourceId: source.id,
      eventId: "\(source.id)-\(record.t)-\(payloadDigest.prefix(12))",
      provider: "webhooky",
      eventType: source.resolvedEventType,
      receivedAt: Date(timeIntervalSince1970: TimeInterval(record.t)),
      dedupeKey: "\(source.id):\(payloadDigest)",
      input: [
        "receivedAt": .string(webhookyISOTimestamp(record.t)),
        "fetched": .bool(record.fetched),
        "payload": payload
      ]
    )
    let triggerResult = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
      sources: config.sources,
      bindings: config.bindings,
      envelope: envelope
    ))
    guard triggerResult.accepted else {
      return 0
    }
    for trigger in triggerResult.triggers {
      guard let workflowName = trigger.workflowName else {
        continue
      }
      _ = try await workflowRunner.runWorkflow(EventWorkflowRunRequest(
        workflowName: workflowName,
        runtimeVariables: trigger.runtimeVariables,
        parsed: parsed
      ))
      try? writeServeRecord(
        eventRoot: eventRoot,
        status: "ready",
        pollingTarget: source.id,
        lastWorkflowName: workflowName
      )
    }
    return 1
  }
}

/// Collects records pushed by the long-lived WebSocket tasks so the serve loop
/// can dispatch them on its own single-threaded cadence.
actor WebhookyRecordBuffer {
  private var queued: [(sourceId: String, record: WebhookRecord)] = []
  private var finishedSourceIds: Set<String> = []

  func append(sourceId: String, record: WebhookRecord) {
    queued.append((sourceId, record))
  }

  func markFinished(sourceId: String) {
    finishedSourceIds.insert(sourceId)
  }

  func drain() -> [(sourceId: String, record: WebhookRecord)] {
    let drained = queued
    queued = []
    return drained
  }

  func allFinished(sourceIds: [String]) -> Bool {
    !sourceIds.isEmpty && finishedSourceIds.isSuperset(of: sourceIds) && queued.isEmpty
  }
}

extension EventLiveConfig {
  func webhookySources(eventRoot: URL) throws -> [WebhookyStreamSource] {
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let boundSourceIds = Set(bindings.filter(\.enabled).map(\.sourceId))
    let sourceIds = Set(sources.filter { source in
      source.enabled && source.kind == .webhooky && boundSourceIds.contains(source.id)
    }.map(\.id))
    guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        let data = try Data(contentsOf: url)
        let contract = try JSONDecoder().decode(EventSourceContract.self, from: data)
        guard sourceIds.contains(contract.id) else {
          return nil
        }
        return try JSONDecoder().decode(WebhookyStreamSource.self, from: data)
      }
  }
}

struct WebhookyStreamSource: Decodable, Equatable, Sendable {
  struct ResolvedConnection {
    var baseURL: String
    var apiKey: String
    var apiSecret: String
    var fetchUUID: String
  }

  var id: String
  /// Environment variable naming the web-hooky server base URL.
  var baseUrlEnv: String
  /// Environment variable holding the fetch API credential as `keyId:secret`.
  var credentialEnv: String
  /// Environment variable naming the destination fetch UUID.
  var fetchUuidEnv: String
  /// Event type stamped on emitted envelopes; bindings match on it.
  var eventType: String?
  /// Also dispatch records that were already marked fetched by an earlier
  /// read. Off by default so reconnect backlogs are not replayed.
  var includeFetched: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case baseUrlEnv
    case credentialEnv
    case fetchUuidEnv
    case eventType
    case includeFetched
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.baseUrlEnv = try container.decode(String.self, forKey: .baseUrlEnv)
    self.credentialEnv = try container.decode(String.self, forKey: .credentialEnv)
    self.fetchUuidEnv = try container.decode(String.self, forKey: .fetchUuidEnv)
    self.eventType = try container.decodeIfPresent(String.self, forKey: .eventType)
    self.includeFetched = try container.decodeIfPresent(Bool.self, forKey: .includeFetched) ?? false
  }

  init(
    id: String,
    baseUrlEnv: String,
    credentialEnv: String,
    fetchUuidEnv: String,
    eventType: String? = nil,
    includeFetched: Bool = false
  ) {
    self.id = id
    self.baseUrlEnv = baseUrlEnv
    self.credentialEnv = credentialEnv
    self.fetchUuidEnv = fetchUuidEnv
    self.eventType = eventType
    self.includeFetched = includeFetched
  }

  var resolvedEventType: String {
    let trimmed = eventType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "webhook.record" : trimmed
  }

  func validateEnvironment(environment: [String: String]) throws {
    _ = try resolvedConnection(environment: environment)
  }

  func resolvedConnection(environment: [String: String]) throws -> ResolvedConnection {
    guard let baseURL = environment[baseUrlEnv], !baseURL.isEmpty else {
      throw CLIUsageError("webhooky source '\(id)' requires environment variable '\(baseUrlEnv)'")
    }
    guard let credential = environment[credentialEnv], !credential.isEmpty else {
      throw CLIUsageError("webhooky source '\(id)' requires environment variable '\(credentialEnv)'")
    }
    let parts = credential.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
      throw CLIUsageError("webhooky source '\(id)' credential in '\(credentialEnv)' must be 'keyId:secret'")
    }
    guard let fetchUUID = environment[fetchUuidEnv], !fetchUUID.isEmpty else {
      throw CLIUsageError("webhooky source '\(id)' requires environment variable '\(fetchUuidEnv)'")
    }
    return ResolvedConnection(
      baseURL: baseURL,
      apiKey: parts[0],
      apiSecret: parts[1],
      fetchUUID: fetchUUID
    )
  }
}

func webhookyJSONValue(_ value: AnyJSON) -> JSONValue {
  switch value {
  case .null:
    return .null
  case let .bool(flag):
    return .bool(flag)
  case let .number(number):
    if number.rounded() == number, number.magnitude < 9_007_199_254_740_992 {
      return .integer(Int64(number))
    }
    return .number(number)
  case let .string(text):
    return .string(text)
  case let .array(values):
    return .array(values.map(webhookyJSONValue))
  case let .object(object):
    return .object(object.mapValues(webhookyJSONValue))
  }
}

private func webhookyPayloadDigest(_ payload: JSONValue, t: Int) -> String {
  let encoded = (try? payload.compactJSONString()) ?? ""
  let digest = SHA256.hash(data: Data("\(t):\(encoded)".utf8))
  return digest.map { String(format: "%02x", $0) }.joined()
}

private func webhookyISOTimestamp(_ unixSeconds: Int) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
}
