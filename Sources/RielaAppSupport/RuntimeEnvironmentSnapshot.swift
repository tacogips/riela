import Foundation

public struct RuntimeEnvironmentScope: Hashable, Sendable {
  public var profile: String
  public var instanceIdentity: String
  public init(profile: String, instanceIdentity: String) {
    self.profile = profile; self.instanceIdentity = instanceIdentity
  }
}

public enum RuntimeEnvironmentError: String, Error, Codable, Sendable, LocalizedError, CustomStringConvertible {
  case notPrepared = "environment_not_prepared"
  case invalidConfiguration = "environment_configuration_invalid"
  case sourceFailed = "environment_source_failed"
  case sourceTimeout = "environment_source_timeout"
  case outputTooLarge = "environment_source_output_too_large"
  case outputInvalid = "environment_source_output_invalid"
  case requiredMissing = "environment_required_missing"
  /// A reload would change the managed-name set of a running channel child.
  case restartRequired = "environment_restart_required"
  /// Another reload for the same scope is still running its loaders.
  case reloadInProgress = "environment_reload_in_progress"
  /// The instance's child was (re)started or stopped while loaders ran.
  case instanceChanged = "environment_instance_changed"
  public var errorDescription: String? { rawValue }
  public var description: String { rawValue }
}

public struct RuntimeEnvironmentStatus: Codable, Equatable, Sendable {
  public enum Readiness: String, Codable, Sendable { case unprepared, ready, failed }
  public var names: [String]
  public var configuredNames: [String]
  public var missingNames: [String]
  public var sourceIDs: [String]
  public var generation: UInt64
  public var readiness: Readiness
  public var lastError: RuntimeEnvironmentError?
  public init(names: [String] = [], configuredNames: [String] = [], missingNames: [String] = [],
              sourceIDs: [String] = [], generation: UInt64 = 0, readiness: Readiness = .unprepared,
              lastError: RuntimeEnvironmentError? = nil) {
    self.names = names; self.configuredNames = configuredNames; self.missingNames = missingNames
    self.sourceIDs = sourceIDs; self.generation = generation; self.readiness = readiness; self.lastError = lastError
  }
}

/// Dedicated execution-only channel. Deliberately not Codable.
public struct RuntimeEnvironmentSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let generation: UInt64
  public let names: [String]
  private let values: [String: String]
  public init(generation: UInt64, names: [String], environment: [String: String]) {
    self.generation = generation; self.names = names; self.values = environment
  }
  public func runtimeEnvironment() -> [String: String] { values }
  public var description: String { "RuntimeEnvironmentSnapshot(generation: \(generation), names: \(names))" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["generation": generation, "names": names]) }
}

/// Wire contract of the private parent->child runtime-environment channel
/// (`riela events serve --runtime-environment-channel`). One JSON object per
/// line in each direction; both ends share these types and bounds.
public enum RuntimeEnvironmentChannelWire {
  /// Maximum encoded frame size, excluding the trailing newline.
  public static let maxFrameBytes = 1_048_576
  public static let acknowledgementType = "runtime-environment-ack"
}

/// Parent->child value-bearing frame. Never logged; description omits values.
public struct RuntimeEnvironmentChannelFrame: Codable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable {
  public var generation: UInt64
  public var managedNames: [String]
  public var values: [String: String]
  public init(generation: UInt64, managedNames: [String], values: [String: String]) {
    self.generation = generation; self.managedNames = managedNames; self.values = values
  }
  /// Newline-terminated wire line. Throws `outputTooLarge` above the shared bound.
  public func encodedLine() throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(self)
    guard data.count <= RuntimeEnvironmentChannelWire.maxFrameBytes else { throw RuntimeEnvironmentError.outputTooLarge }
    data.append(10)
    return data
  }
  public var description: String { "RuntimeEnvironmentChannelFrame(generation: \(generation), managedNames: \(managedNames))" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["generation": generation, "managedNames": managedNames]) }
}

/// Child->parent acknowledgement. Carries names and a safe code, never values.
public struct RuntimeEnvironmentChannelAcknowledgement: Codable, Equatable, Sendable {
  public var type: String
  public var generation: UInt64?
  public var names: [String]
  public var accepted: Bool
  public var error: String?
  public init(type: String = RuntimeEnvironmentChannelWire.acknowledgementType, generation: UInt64?,
              names: [String], accepted: Bool, error: String? = nil) {
    self.type = type; self.generation = generation; self.names = names; self.accepted = accepted; self.error = error
  }
  /// Decodes one stdout line; returns nil for anything that is not an ACK.
  public static func decodeLine(_ line: Data) -> RuntimeEnvironmentChannelAcknowledgement? {
    guard let ack = try? JSONDecoder().decode(Self.self, from: line),
      ack.type == RuntimeEnvironmentChannelWire.acknowledgementType else { return nil }
    return ack
  }
}
