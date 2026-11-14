import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import KaibaClient
import RielaCore

public enum KaibaInstanceAuthentication: Codable, Equatable, Sendable {
  case bearer(environmentVariable: String)
  case unauthenticated

  private enum CodingKeys: String, CodingKey {
    case mode
    case environmentVariable
  }

  private enum Mode: String, Codable {
    case bearer
    case unauthenticated
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Mode.self, forKey: .mode) {
    case .bearer:
      self = .bearer(environmentVariable: try container.decode(String.self, forKey: .environmentVariable))
    case .unauthenticated:
      self = .unauthenticated
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .bearer(environmentVariable):
      try container.encode(Mode.bearer, forKey: .mode)
      try container.encode(environmentVariable, forKey: .environmentVariable)
    case .unauthenticated:
      try container.encode(Mode.unauthenticated, forKey: .mode)
    }
  }

  public var credentialEnvironmentVariable: String? {
    guard case let .bearer(environmentVariable) = self else { return nil }
    return environmentVariable
  }
}

public enum KaibaInstanceLastTestStatus: String, Codable, Equatable, Sendable {
  case untested
  case ready
  case disabled
  case missingCredential = "missing_credential"
  case authFailed = "auth_failed"
  case connectionFailed = "connection_failed"
  case incompatible
}

public struct KaibaInstanceLastTest: Codable, Equatable, Sendable {
  public var status: KaibaInstanceLastTestStatus
  public var code: String?
  public var attemptedAt: Date?

  public init(status: KaibaInstanceLastTestStatus = .untested, code: String? = nil, attemptedAt: Date? = nil) {
    self.status = status
    self.code = code
    self.attemptedAt = attemptedAt
  }
}

public struct KaibaInstance: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var endpoint: String
  public var authentication: KaibaInstanceAuthentication
  public var enabled: Bool
  public var isDefault: Bool
  public var allowInsecureHTTP: Bool
  public var allowRemoteUnauthenticated: Bool
  public var lastTest: KaibaInstanceLastTest

  public init(
    id: String = UUID().uuidString.lowercased(),
    name: String,
    endpoint: String,
    authentication: KaibaInstanceAuthentication,
    enabled: Bool = true,
    isDefault: Bool = false,
    allowInsecureHTTP: Bool = false,
    allowRemoteUnauthenticated: Bool = false,
    lastTest: KaibaInstanceLastTest = .init()
  ) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.authentication = authentication
    self.enabled = enabled
    self.isDefault = isDefault
    self.allowInsecureHTTP = allowInsecureHTTP
    self.allowRemoteUnauthenticated = allowRemoteUnauthenticated
    self.lastTest = lastTest
  }
}

/// Centralizes state transitions that alter the safe readiness history. Both
/// CLI and future App writers must use this rule so stale readiness evidence
/// is never presented for a changed transport configuration.
public enum KaibaInstanceLifecycle {
  public static func applyingUpdate(
    from original: KaibaInstance,
    to replacement: KaibaInstance,
    at date: Date
  ) throws -> KaibaInstance {
    var updated = replacement
    // Compare the persisted representation. A server root and /graphql are
    // equivalent endpoint forms and must retain the same readiness evidence.
    updated.endpoint = try KaibaInstanceValidation.normalizedEndpoint(updated)
    switch (original.enabled, updated.enabled) {
    case (true, false):
      updated.lastTest = disabledResult(at: date)
    case (false, true):
      updated.lastTest = .init()
    case (_, true) where transportChanged(from: original, to: updated):
      updated.lastTest = .init()
    default:
      updated.lastTest = original.lastTest
    }
    return updated
  }

  public static func disabledResult(at date: Date) -> KaibaInstanceLastTest {
    .init(status: .disabled, code: "disabled_kaiba_instance", attemptedAt: date)
  }

  public static func transportChanged(from original: KaibaInstance, to replacement: KaibaInstance) -> Bool {
    original.endpoint != replacement.endpoint
      || original.authentication != replacement.authentication
      || original.allowInsecureHTTP != replacement.allowInsecureHTTP
      || original.allowRemoteUnauthenticated != replacement.allowRemoteUnauthenticated
  }
}

public struct KaibaInstanceCatalog: Codable, Equatable, Sendable {
  public static let schemaVersion = 1

  public var schemaVersion: Int
  public var instances: [KaibaInstance]

  public init(schemaVersion: Int = Self.schemaVersion, instances: [KaibaInstance] = []) {
    self.schemaVersion = schemaVersion
    self.instances = instances
  }
}

public enum KaibaInstanceStoreError: Error, Equatable, Sendable {
  case invalidStore
  case unavailable
  case invalidInstance
  case duplicateName
  case missingInstance
  case defaultInvariant
  case changedInstance

  public var code: String {
    switch self {
    case .invalidStore: "invalid_kaiba_instance_store"
    case .unavailable: "kaiba_instance_store_unavailable"
    case .invalidInstance: "invalid_kaiba_instance"
    case .duplicateName: "duplicate_kaiba_instance_name"
    case .missingInstance: "unknown_kaiba_instance"
    case .defaultInvariant: "invalid_kaiba_instance_default"
    case .changedInstance: "kaiba_instance_changed"
    }
  }
}

public enum KaibaInstanceValidation {
  public static func validated(_ catalog: KaibaInstanceCatalog) throws -> KaibaInstanceCatalog {
    guard catalog.schemaVersion == KaibaInstanceCatalog.schemaVersion else {
      throw KaibaInstanceStoreError.invalidStore
    }
    let defaults = catalog.instances.filter(\.isDefault)
    guard catalog.instances.isEmpty ? defaults.isEmpty : defaults.count == 1,
          defaults.allSatisfy(\.enabled) else {
      throw KaibaInstanceStoreError.defaultInvariant
    }
    var ids = Set<String>()
    var names = Set<String>()
    var normalizedInstances: [KaibaInstance] = []
    for var instance in catalog.instances {
      instance.name = try normalizedName(instance.name)
      guard UUID(uuidString: instance.id)?.uuidString.lowercased() == instance.id,
            ids.insert(instance.id).inserted,
            names.insert(nameKey(instance.name)).inserted else {
        throw KaibaInstanceStoreError.invalidInstance
      }
      instance.endpoint = try normalizedEndpoint(instance)
      if case let .bearer(environmentVariable) = instance.authentication {
        guard environmentVariable.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
          throw KaibaInstanceStoreError.invalidInstance
        }
      }
      normalizedInstances.append(instance)
    }
    return KaibaInstanceCatalog(schemaVersion: catalog.schemaVersion, instances: normalizedInstances)
  }

  public static func validateEndpoint(_ instance: KaibaInstance) throws {
    _ = try normalizedEndpoint(instance)
  }

  public static func normalizedName(_ rawName: String) throws -> String {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    guard (1...80).contains(name.count),
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw KaibaInstanceStoreError.invalidInstance
    }
    return name
  }

  public static func nameKey(_ name: String) -> String {
    name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  public static func normalizedEndpoint(_ instance: KaibaInstance) throws -> String {
    guard let endpoint = URL(string: instance.endpoint),
          endpoint.host != nil,
          endpoint.path == "" || endpoint.path == "/" || endpoint.path == "/graphql",
          endpoint.query == nil,
          endpoint.fragment == nil,
          endpoint.user == nil,
          endpoint.password == nil,
          !instance.endpoint.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw KaibaInstanceStoreError.invalidInstance
    }
    let isLoopback = endpoint.host.map(isLoopbackHost) ?? false
    switch endpoint.scheme?.lowercased() {
    case "https": break
    case "http" where isLoopback || instance.allowInsecureHTTP: break
    default: throw KaibaInstanceStoreError.invalidInstance
    }
    if case .unauthenticated = instance.authentication, !isLoopback, !instance.allowRemoteUnauthenticated {
      throw KaibaInstanceStoreError.invalidInstance
    }
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw KaibaInstanceStoreError.invalidInstance
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
      components.port = nil
    }
    components.path = "/graphql"
    guard let normalized = components.url else { throw KaibaInstanceStoreError.invalidInstance }
    return normalized.absoluteString
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard normalized != "localhost" else { return true }
    var ipv4 = in_addr()
    if inet_pton(AF_INET, normalized, &ipv4) == 1 {
      return (UInt32(bigEndian: ipv4.s_addr) & 0xFF00_0000) == 0x7F00_0000
    }
    var ipv6 = in6_addr()
    guard inet_pton(AF_INET6, normalized, &ipv6) == 1 else { return false }
    return withUnsafeBytes(of: ipv6) { bytes in
      bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
  }
}
