import Foundation
import RielaServer

public struct RielaAppInstanceCancelRequest: Codable, Equatable, Sendable {
  public var expectedProfile: String
  public var reason: String

  public init(expectedProfile: String, reason: String) {
    self.expectedProfile = expectedProfile
    self.reason = reason
  }

  public static func decodeStrict(_ body: Data) throws -> Self {
    do {
      guard body.count <= 65_536, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
        Set(object.keys) == Set(["expectedProfile", "reason"]) else {
        throw RielaAppInstanceCancelError(code: .invalidCancelRequest)
      }
      var request = try JSONDecoder().decode(Self.self, from: body)
      request.reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...512).contains(request.reason.utf8.count), !request.reason.contains("\0") else {
        throw RielaAppInstanceCancelError(code: .invalidCancelRequest)
      }
      return request
    } catch {
      throw RielaAppInstanceCancelError(code: .invalidCancelRequest)
    }
  }
}

public enum RielaAppInstanceCancelCode: String, Codable, Sendable, CaseIterable {
  case invalidCancelRequest = "invalid_cancel_request"
  case instanceNotFound = "instance_not_found"
  case sessionNotFound = "session_not_found"
  case configurationConflict = "configuration_conflict"
  case notRunning = "not_running"
  case sessionNotOwned = "session_not_owned"
  case cancelUnavailable = "cancel_unavailable"
  case instanceBusy = "instance_busy"
  case noRunningExecution = "no_running_execution"
  case ambiguousRunningSessions = "ambiguous_running_sessions"

  public var httpStatus: Int {
    switch self {
    case .invalidCancelRequest: 400
    case .instanceNotFound, .sessionNotFound: 404
    default: 409
    }
  }
}

public struct RielaAppInstanceCancelError: Error, Equatable, Sendable {
  public var code: RielaAppInstanceCancelCode
  public var message: String
  public var sessionIds: [String]?
  public var pendingRunCount: Int?

  public init(code: RielaAppInstanceCancelCode, message: String = "", sessionIds: [String]? = nil, pendingRunCount: Int? = nil) {
    self.code = code
    self.message = message
    self.sessionIds = sessionIds
    self.pendingRunCount = pendingRunCount
  }
}

public struct RielaAppInstanceCancelResponse: Codable, Equatable, Sendable {
  public var identity: String
  public var profile: String
  public var sessionId: String
  public var owner: String
  public var outcome: String

  public init(identity: String, profile: String, sessionId: String, owner: String, outcome: String) {
    self.identity = identity
    self.profile = profile
    self.sessionId = sessionId
    self.owner = owner
    self.outcome = outcome
  }
}

public struct RielaAppLiveSessionInventory: Equatable, Sendable {
  public var sessionIds: [String]
  public var pendingRunCount: Int

  public init(sessionIds: [String], pendingRunCount: Int) {
    self.sessionIds = sessionIds
    self.pendingRunCount = pendingRunCount
  }
}

public enum RielaAppStoredSessionState: Equatable, Sendable {
  case absent, terminal, nonTerminal
}

public enum RielaAppInstanceCancelActor {
  public static let rielaAppCancelActorPrefix = "rielaapp-api:"
  public static func actor(profile: String) -> String { rielaAppCancelActorPrefix + profile }
}

public protocol RielaAppInstanceCancelPorts: Sendable {
  func profile() async -> String
  func instanceExists(identity: String) async -> Bool
  func cancelAppLaunch(identity: String, sessionId: String, reason: String, actor: String) async -> WorkflowServeSessionCancelOutcome
  func appInventory(identity: String) async -> RielaAppLiveSessionInventory
  func childRunning(identity: String) async -> Bool
  func childSessionControl(identity: String, frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement
  func storedSessionState(identity: String, sessionId: String) async -> RielaAppStoredSessionState
}
