import Foundation
import RielaCore
import RielaServer

public struct RielaAppInstanceReloadRequest: Codable, Equatable, Sendable {
  public var expectedProfile: String
  public var expectedRevision: Int
  public var reason: String
  public var workflowDirectory: String?
  public var interruptRunning: Bool

  public init(expectedProfile: String, expectedRevision: Int, reason: String, workflowDirectory: String?, interruptRunning: Bool) {
    self.expectedProfile = expectedProfile
    self.expectedRevision = expectedRevision
    self.reason = reason
    self.workflowDirectory = workflowDirectory
    self.interruptRunning = interruptRunning
  }

  public static func decodeStrict(_ body: Data) throws -> Self {
    do {
      guard body.count <= 65_536,
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
        Set(object.keys) == Set(["expectedProfile", "expectedRevision", "reason", "workflowDirectory", "interruptRunning"]) else {
        throw RielaAppInstanceReloadError(code: .invalidReloadRequest)
      }
      var request = try JSONDecoder().decode(Self.self, from: body)
      request.reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...512).contains(request.reason.utf8.count) else { throw RielaAppInstanceReloadError(code: .invalidReloadRequest) }
      if let path = request.workflowDirectory {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw RielaAppInstanceReloadError(code: .invalidReloadRequest) }
        request.workflowDirectory = URL(fileURLWithPath: path).standardizedFileURL.path
      }
      return request
    } catch {
      throw RielaAppInstanceReloadError(code: .invalidReloadRequest)
    }
  }
}

public enum RielaAppInstanceReloadCode: String, Codable, Sendable, CaseIterable {
  case invalidReloadRequest = "invalid_reload_request"
  case instanceNotFound = "instance_not_found"
  case configurationConflict = "configuration_conflict"
  case invalidWorkflowSource = "invalid_workflow_source"
  case invalidWorkflowDefinition = "invalid_workflow_definition"
  case workflowIdMismatch = "workflow_id_mismatch"
  case invalidEventBindings = "invalid_event_bindings"
  case instanceRunInFlight = "instance_run_in_flight"
  case instanceHandoffUnavailable = "instance_handoff_unavailable"
  case definitionConflict = "definition_conflict"
  case definitionStoreFailure = "definition_store_failure"
  case configurationIOFailure = "configuration_io_failure"
  case instanceStartFailed = "instance_start_failed"
  case instanceNotReady = "instance_not_ready"
  case instanceBusy = "instance_busy"

  public var httpStatus: Int {
    switch self {
    case .invalidReloadRequest: 400
    case .instanceNotFound: 404
    case .configurationConflict, .instanceRunInFlight, .instanceHandoffUnavailable, .definitionConflict, .instanceBusy: 409
    case .invalidWorkflowSource, .invalidWorkflowDefinition, .workflowIdMismatch, .invalidEventBindings,
         .instanceStartFailed, .instanceNotReady: 422
    case .definitionStoreFailure, .configurationIOFailure: 500
    }
  }
}

public struct RielaAppInstanceReloadError: Error, Equatable, Sendable {
  public var code: RielaAppInstanceReloadCode
  public var message: String
  public var committed: Bool
  public var partial: String?
  public var running: Int?
  public var queued: Int?

  public init(code: RielaAppInstanceReloadCode, message: String = "", committed: Bool = false,
              partial: String? = nil, running: Int? = nil, queued: Int? = nil) {
    self.code = code
    self.message = message
    self.committed = committed
    self.partial = partial
    self.running = running
    self.queued = queued
  }
}

public struct RielaAppInstanceReloadResponse: Codable, Equatable, Sendable {
  public struct Definition: Codable, Equatable, Sendable {
    public var outcome: String
    public var versionId: String?
    public var digest: String?
    public init(outcome: String, versionId: String?, digest: String?) {
      self.outcome = outcome
      self.versionId = versionId
      self.digest = digest
    }
  }
  public struct EventBindings: Codable, Equatable, Sendable {
    public var respawnRequired: Bool
    public var respawned: Bool
    public init(respawnRequired: Bool, respawned: Bool) {
      self.respawnRequired = respawnRequired
      self.respawned = respawned
    }
  }
  public var profile: String
  public var revision: Int
  public var identity: String
  public var workflowId: String
  public var workflowDirectory: String
  public var sourceChanged: Bool
  public var definition: Definition
  public var eventBindings: EventBindings
  public var handoff: String
  public var runtimeStatus: String
  public var committed: Bool
  public init(profile: String, revision: Int, identity: String, workflowId: String, workflowDirectory: String,
              sourceChanged: Bool, definition: Definition, eventBindings: EventBindings, handoff: String,
              runtimeStatus: String, committed: Bool) {
    self.profile = profile
    self.revision = revision
    self.identity = identity
    self.workflowId = workflowId
    self.workflowDirectory = workflowDirectory
    self.sourceChanged = sourceChanged
    self.definition = definition
    self.eventBindings = eventBindings
    self.handoff = handoff
    self.runtimeStatus = runtimeStatus
    self.committed = committed
  }
}

public struct RielaAppInstanceStartRecord: Equatable, Sendable {
  public var workflowDirectory: String
  public var eventRoot: String?
  public var eventRootDigest: String
  public var triggerDefaultsFingerprint: String
  public init(workflowDirectory: String, eventRoot: String?, eventRootDigest: String, triggerDefaultsFingerprint: String) {
    self.workflowDirectory = workflowDirectory
    self.eventRoot = eventRoot
    self.eventRootDigest = eventRootDigest
    self.triggerDefaultsFingerprint = triggerDefaultsFingerprint
  }
}

public enum RielaAppInstanceReloadFingerprint {
  public static func eventRootDigest(eventRoot: String?) throws -> String {
    guard let eventRoot, FileManager.default.fileExists(atPath: eventRoot) else { return JSONCanonical.sha256Hex(Data()) }
    let root = URL(fileURLWithPath: eventRoot, isDirectory: true).standardizedFileURL
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      errorHandler: { _, error in enumerationError = error; return false }) else {
      throw CocoaError(.fileReadUnknown)
    }
    var files: [(String, URL)] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
      if values.isRegularFile == true { files.append((String(url.path.dropFirst(root.path.count + 1)), url)) }
    }
    if let enumerationError { throw enumerationError }
    var material = Data()
    for (path, url) in files.sorted(by: { $0.0 < $1.0 }) {
      let data = try Data(contentsOf: url)
      material.append(contentsOf: "\(path)\0\(data.count)\0".utf8)
      material.append(data)
    }
    return JSONCanonical.sha256Hex(material)
  }

  public static func triggerDefaultsFingerprint(_ value: EventOverlapSettings?) -> String {
    guard let value else { return JSONCanonical.sha256Hex(Data("none".utf8)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return JSONCanonical.sha256Hex((try? encoder.encode(value)) ?? Data())
  }

  public static func respawnRequired(childRunning: Bool, installed: RielaAppInstanceStartRecord?,
                                     proposed: RielaAppInstanceStartRecord) -> Bool {
    childRunning && installed != proposed
  }
}

public struct RielaAppInstanceReloadInstance: Equatable, Sendable {
  public var identity: String
  public var workflowId: String
  public var sourceId: String
  public var workflowDirectory: String
  public var eventRoot: String?
  public init(identity: String, workflowId: String, sourceId: String, workflowDirectory: String, eventRoot: String?) {
    self.identity = identity
    self.workflowId = workflowId
    self.sourceId = sourceId
    self.workflowDirectory = workflowDirectory
    self.eventRoot = eventRoot
  }
}

public struct RielaAppInstanceReloadCandidate: Equatable, Sendable {
  public var sourceId: String
  public var workflowDirectory: String
  public var eventRoot: String?
  public var sourceChanged: Bool
  public init(sourceId: String, workflowDirectory: String, eventRoot: String?, sourceChanged: Bool) {
    self.sourceId = sourceId
    self.workflowDirectory = workflowDirectory
    self.eventRoot = eventRoot
    self.sourceChanged = sourceChanged
  }
}

public struct RielaAppInstanceReloadValidated: Equatable, Sendable {
  public var workflowId: String
  public var triggerDefaultsFingerprint: String
  public var eventRootDigest: String
  public init(workflowId: String, triggerDefaultsFingerprint: String, eventRootDigest: String) {
    self.workflowId = workflowId
    self.triggerDefaultsFingerprint = triggerDefaultsFingerprint
    self.eventRootDigest = eventRootDigest
  }
}

public protocol RielaAppInstanceReloadPorts: Sendable {
  func currentInstance(identity: String) async -> RielaAppInstanceReloadInstance?
  func validateRevision(expectedRevision: Int, expectedProfile: String) async throws
  func discoverCandidate(instance: RielaAppInstanceReloadInstance, requestedDirectory: String?) async throws -> RielaAppInstanceReloadCandidate
  func validate(candidate: RielaAppInstanceReloadCandidate, instance: RielaAppInstanceReloadInstance) async throws -> RielaAppInstanceReloadValidated
  func installedStartRecord(identity: String) async -> RielaAppInstanceStartRecord?
  func childRunning(identity: String) async -> Bool
  func admission(identity: String, frame: WorkflowServeAdmissionFrame) async throws -> WorkflowServeAdmissionAcknowledgement
  func importDefinition(candidate: RielaAppInstanceReloadCandidate, reason: String) async throws -> RielaAppInstanceReloadResponse.Definition
  func relink(identity: String, candidate: RielaAppInstanceReloadCandidate) async throws -> Int
  func refreshCache() async
  func replaceChild(identity: String, interrupt: Bool) async throws -> String
  func profile() async -> String
  func revision() async -> Int
}
