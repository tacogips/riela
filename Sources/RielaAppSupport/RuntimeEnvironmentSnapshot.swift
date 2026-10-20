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
