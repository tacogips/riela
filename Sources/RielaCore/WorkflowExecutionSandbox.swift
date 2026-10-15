import Foundation

public enum WorkflowSandboxBackend: String, Codable, Sendable {
  case auto
  case container
  case seatbelt
  case bubblewrap
}

/// Project only the selected host credential into the sandbox's private HOME.
/// The host source is never mounted writable or updated by a vendor refresh.
public struct WorkflowSandboxCredential: Codable, Equatable, Sendable {
  public var source: String
  public var homePath: String

  public init(source: String, homePath: String) {
    self.source = source
    self.homePath = homePath
  }
}

/// OS-enforced isolation, independent of a vendor CLI's permission flags.
public struct WorkflowExecutionSandbox: Codable, Equatable, Sendable {
  public var backend: WorkflowSandboxBackend
  public var networkPolicy: WorkflowAddonContainerNetworkPolicy
  public var readPaths: [String]
  public var writePaths: [String]
  public var credentialPaths: [String]
  public var credentials: [WorkflowSandboxCredential]
  public var environment: [String]
  public var container: WorkflowAddonContainerExecution?

  public init(backend: WorkflowSandboxBackend = .auto,
              networkPolicy: WorkflowAddonContainerNetworkPolicy = .denied,
              readPaths: [String] = [], writePaths: [String] = [], credentialPaths: [String] = [],
              environment: [String] = [], container: WorkflowAddonContainerExecution? = nil,
              credentials: [WorkflowSandboxCredential] = []) {
    self.backend = backend
    self.networkPolicy = networkPolicy
    self.readPaths = readPaths
    self.writePaths = writePaths
    self.credentialPaths = credentialPaths
    self.credentials = credentials
    self.environment = environment
    self.container = container
  }

  private enum CodingKeys: String, CodingKey {
    case backend, networkPolicy, readPaths, writePaths, credentialPaths, credentials, environment, container
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    backend = try values.decodeIfPresent(WorkflowSandboxBackend.self, forKey: .backend) ?? .auto
    networkPolicy = try values.decodeIfPresent(WorkflowAddonContainerNetworkPolicy.self, forKey: .networkPolicy) ?? .denied
    readPaths = try values.decodeIfPresent([String].self, forKey: .readPaths) ?? []
    writePaths = try values.decodeIfPresent([String].self, forKey: .writePaths) ?? []
    credentialPaths = try values.decodeIfPresent([String].self, forKey: .credentialPaths) ?? []
    credentials = try values.decodeIfPresent([WorkflowSandboxCredential].self, forKey: .credentials) ?? []
    environment = try values.decodeIfPresent([String].self, forKey: .environment) ?? []
    container = try values.decodeIfPresent(WorkflowAddonContainerExecution.self, forKey: .container)
    try validate()
  }

  public func validate() throws {
    for path in readPaths + writePaths + credentialPaths + credentials.map(\.source) {
      guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path != "/",
            !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
        throw AdapterExecutionError(.policyBlocked, "sandbox paths must be non-root absolute paths without control characters")
      }
    }
    var targets: [String] = []
    for credential in credentials {
      let target = credential.homePath
      let components = target.split(separator: "/", omittingEmptySubsequences: false)
      guard !target.hasPrefix("/"), !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            !target.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            !targets.contains(where: { $0 == target || $0.hasPrefix(target + "/") || target.hasPrefix($0 + "/") }) else {
        throw AdapterExecutionError(.policyBlocked, "sandbox credential HOME paths must be distinct, non-overlapping relative paths")
      }
      targets.append(target)
    }
    for name in environment {
      guard isValidEnvironmentVariableName(name), !Self.reservedEnvironment.contains(name),
            !name.hasPrefix("DYLD_"), !name.hasPrefix("LD_") else {
        throw AdapterExecutionError(.policyBlocked, "sandbox environment contains an invalid or runtime-owned name")
      }
    }
    guard backend == .container || container == nil else {
      throw AdapterExecutionError(.policyBlocked, "sandbox.container requires backend=container")
    }
    try container?.validate()
  }

  public static let reservedEnvironment: Set<String> = ["HOME", "TMPDIR", "TMP", "TEMP", "RIELA_ADDON_STATE_DIR"]
}
