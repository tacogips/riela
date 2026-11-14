import Foundation
import RielaCore
import RielaServer

public enum RielaAppControlOperation: Equatable, Sendable {
  case bootstrap
  case reload(identity: String, body: Data)
  case run(identity: String, body: Data)
  case cancel(identity: String, sessionId: String?, body: Data)
  case environmentStatus(identity: String)
  case environmentReload(identity: String, body: Data)
  case launchStatus(launchId: String)

  public var wireName: String {
    switch self {
    case .bootstrap: "bootstrap"
    case .reload: "instance.reload"
    case .run: "instance.run"
    case .cancel: "instance.cancel"
    case .environmentStatus: "environment.status"
    case .environmentReload: "environment.reload"
    case .launchStatus: "launch.status"
    }
  }

  public var isReadOnly: Bool {
    switch self {
    case .bootstrap, .environmentStatus, .launchStatus: true
    default: false
    }
  }
}

public struct RielaAppControlResult: Equatable, Sendable {
  public var status: Int
  public var body: JSONValue
  public init(status: Int, body: JSONValue) { self.status = status; self.body = body }
  public static func error(status: Int, code: String, message: String? = nil) -> Self {
    var error: JSONObject = ["code": .string(code)]
    if let message { error["message"] = .string(message) }
    return Self(status: status, body: .object(["error": .object(error)]))
  }
  public init(httpResponse: RielaHTTPResponse) {
    self.init(status: httpResponse.status, body: (try? JSONDecoder().decode(JSONValue.self, from: httpResponse.body)) ?? .null)
  }
  public var httpResponse: RielaHTTPResponse { .json(status: status, body) }
}

public struct RielaAppControlBootstrap: Codable, Equatable, Sendable {
  public var profile: String
  public var revision: Int
  public init(profile: String, revision: Int) { self.profile = profile; self.revision = revision }
}

public struct RielaAppControlConflict: Error, Equatable, Sendable {
  public var code: String
  public var message: String
  public var status: Int
  public init(code: String, message: String, status: Int) {
    self.code = code; self.message = message; self.status = status
  }
}

public enum RielaAppEnvironmentReloadOutcome: Sendable {
  case reloaded(RuntimeEnvironmentStatus)
  case notReady
  case failed(RuntimeEnvironmentStatus)
}

public struct RielaAppConfiguredRunInput: Equatable, Sendable {
  public var expectedProfile: String
  public var expectedRevision: Int
  public var variables: JSONObject
  public var allowOverlap: Bool?
  public init(expectedProfile: String, expectedRevision: Int, variables: JSONObject, allowOverlap: Bool?) {
    self.expectedProfile = expectedProfile; self.expectedRevision = expectedRevision
    self.variables = variables; self.allowOverlap = allowOverlap
  }
}

public protocol RielaAppInstanceControlPorts: Sendable {
  func profile() async -> String
  func bootstrap() async -> RielaAppControlBootstrap
  func isShuttingDown() async -> Bool
  func serialized(_ body: @escaping @Sendable () async -> RielaAppControlResult) async -> RielaAppControlResult
  func reloadPorts() -> any RielaAppInstanceReloadPorts
  func cancelPorts() -> any RielaAppInstanceCancelPorts
  func validateRevision(expectedRevision: Int, expectedProfile: String) async -> RielaAppControlConflict?
  func instanceExists(identity: String) async -> Bool
  func environmentStatus(identity: String) async -> RuntimeEnvironmentStatus
  func reloadEnvironment(identity: String) async -> RielaAppEnvironmentReloadOutcome
  func launchConfiguredRun(identity: String, input: RielaAppConfiguredRunInput) async -> RielaAppControlResult
  func launchStatus(launchId: String, profile: String) async -> RielaAppControlResult
}

public enum RielaAppControlLimits {
  public static let maxRequestFrameBytes = 589_824
  public static let maxResponseFrameBytes = 1_048_576
  public static let requestReadDeadlineSeconds = 5
  public static let connectTimeoutSeconds = 2
  public static let responseTimeoutSeconds = 30
  public static let idempotencyTTLSeconds = 600
  public static let idempotencyCapacity = 512
  public static let maxSocketPathBytes = 103
  public static let reloadBodyMaxBytes = 65_536
  public static let runBodyMaxBytes = 524_288
  public static let localReloadCapSeconds = 30
}

public enum RielaAppControlErrorCode: String, Sendable {
  case appNotRunning = "app_not_running", appChannelUnavailable = "app_channel_unavailable"
  case appChannelInsecure = "app_channel_insecure", appChannelPathTooLong = "app_channel_path_too_long"
  case appChannelTimeout = "app_channel_timeout", appChannelProtocolError = "app_channel_protocol_error"
  case requestTooLarge = "request_too_large", invalidRequest = "invalid_request"
  case requestIdConflict = "request_id_conflict", channelBusy = "channel_busy"
}

public enum RielaAppControlEnvelopeError: Error, Sendable {
  case invalidRequest, invalidResponse
}

public struct RielaAppControlRequestEnvelope: Equatable, Sendable {
  public var version: Int
  public var requestId: String
  public var operation: RielaAppControlOperation
  public var profile: String

  public init(version: Int = 1, requestId: String, operation: RielaAppControlOperation, profile: String) {
    self.version = version; self.requestId = requestId; self.operation = operation; self.profile = profile
  }

  public static func decodeStrict(_ data: Data) throws -> Self {
    do { return try decode(data) } catch { throw RielaAppControlEnvelopeError.invalidRequest }
  }

  private static func decode(_ data: Data) throws -> Self {
    guard case let .object(values) = try JSONDecoder().decode(JSONValue.self, from: data),
      Set(values.keys) == Set(["version", "requestId", "operation", "profile", "identity", "sessionId", "launchId", "body"]),
      values["version"] == .integer(1),
      case let .string(requestId) = values["requestId"],
      requestId.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil,
      case let .string(name) = values["operation"],
      case let .string(profile) = values["profile"], valid(profile, max: 128),
      let identity = values["identity"], let session = values["sessionId"],
      let launch = values["launchId"], let body = values["body"] else {
      throw RielaAppControlEnvelopeError.invalidRequest
    }
    let operation: RielaAppControlOperation
    switch name {
    case "bootstrap" where identity == .null && session == .null && launch == .null && body == .null:
      operation = .bootstrap
    case "launch.status" where identity == .null && session == .null && body == .null:
      guard case let .string(id) = launch, valid(id, max: 1024) else { throw RielaAppControlEnvelopeError.invalidRequest }
      operation = .launchStatus(launchId: id)
    default:
      guard case let .string(id) = identity, valid(id, max: 1024), launch == .null else {
        throw RielaAppControlEnvelopeError.invalidRequest
      }
      if name == "environment.status", session == .null, body == .null {
        operation = .environmentStatus(identity: id)
      } else {
        guard case .object = body else { throw RielaAppControlEnvelopeError.invalidRequest }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(body)
        switch name {
        case "instance.reload" where session == .null: operation = .reload(identity: id, body: bytes)
        case "instance.run" where session == .null: operation = .run(identity: id, body: bytes)
        case "environment.reload" where session == .null: operation = .environmentReload(identity: id, body: bytes)
        case "instance.cancel":
          let sessionId: String?
          if session == .null {
            sessionId = nil
          } else if case let .string(value) = session, valid(value, max: 1024) {
            sessionId = value
          } else {
            throw RielaAppControlEnvelopeError.invalidRequest
          }
          operation = .cancel(identity: id, sessionId: sessionId, body: bytes)
        default: throw RielaAppControlEnvelopeError.invalidRequest
        }
      }
    }
    return Self(version: 1, requestId: requestId, operation: operation, profile: profile)
  }

  private static func valid(_ value: String, max: Int) -> Bool { (1...max).contains(value.utf8.count) }

  private func values() throws -> JSONObject {
    var result: JSONObject = ["version": .integer(Int64(version)), "requestId": .string(requestId),
                              "operation": .string(operation.wireName), "profile": .string(profile),
                              "identity": .null, "sessionId": .null, "launchId": .null, "body": .null]
    switch operation {
    case .bootstrap: break
    case let .launchStatus(id): result["launchId"] = .string(id)
    case let .environmentStatus(id): result["identity"] = .string(id)
    case let .reload(id, body), let .run(id, body), let .environmentReload(id, body):
      result["identity"] = .string(id); result["body"] = try JSONDecoder().decode(JSONValue.self, from: body)
    case let .cancel(id, session, body):
      result["identity"] = .string(id); result["sessionId"] = session.map(JSONValue.string) ?? .null
      result["body"] = try JSONDecoder().decode(JSONValue.self, from: body)
    }
    return result
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(JSONValue.object(values()))
  }
  public func digest() throws -> String {
    var object = try values(); object.removeValue(forKey: "requestId")
    return try JSONCanonical.sha256Hex(JSONCanonical.encode(JSONValue.object(object)))
  }
}

public struct RielaAppControlResponseEnvelope: Codable, Equatable, Sendable {
  public var version: Int
  public var requestId: String
  public var status: Int
  public var body: JSONValue
  public init(version: Int = 1, requestId: String, status: Int, body: JSONValue) {
    self.version = version; self.requestId = requestId; self.status = status; self.body = body
  }
  public static func decodeStrict(_ data: Data) throws -> Self {
    do {
      guard case let .object(values) = try JSONDecoder().decode(JSONValue.self, from: data),
        Set(values.keys) == Set(["version", "requestId", "status", "body"]) else {
        throw RielaAppControlEnvelopeError.invalidResponse
      }
      return try JSONDecoder().decode(Self.self, from: data)
    } catch { throw RielaAppControlEnvelopeError.invalidResponse }
  }
}
