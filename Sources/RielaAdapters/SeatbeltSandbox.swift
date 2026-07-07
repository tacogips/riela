import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct LocalProcessSandboxPolicy: Equatable, Sendable {
  public enum Enforcement: String, Equatable, Sendable {
    case auto
    case required
  }

  public enum FilesystemWriteScope: Equatable, Sendable {
    case readOnly
    case paths([String])
  }

  public var enforcement: Enforcement
  public var writeScope: FilesystemWriteScope
  public var readPaths: [String]?
  public var networkAllowed: Bool

  public init(
    enforcement: Enforcement = .auto,
    writeScope: FilesystemWriteScope = .readOnly,
    readPaths: [String]? = nil,
    networkAllowed: Bool = true
  ) {
    self.enforcement = enforcement
    self.writeScope = writeScope
    self.readPaths = readPaths
    self.networkAllowed = networkAllowed
  }
}

public struct SeatbeltAvailability: Sendable {
  public var isAvailable: @Sendable () -> Bool

  public init(isAvailable: @escaping @Sendable () -> Bool) {
    self.isAvailable = isAvailable
  }

  public static let executablePath = "/usr/bin/sandbox-exec"

  public static let live = SeatbeltAvailability {
    #if canImport(Darwin)
    return FileManager.default.isExecutableFile(atPath: executablePath)
    #else
    return false
    #endif
  }
}

public enum SeatbeltSandboxMode: String, Equatable, Sendable {
  case off
  case auto
  case required
}

public enum SeatbeltSandboxSettings {
  public static let environmentKey = "RIELA_SANDBOX_SEATBELT"

  public static func mode(environment: [String: String]) throws -> SeatbeltSandboxMode {
    guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return .off
    }
    switch raw.lowercased() {
    case "off":
      return .off
    case "auto":
      return .auto
    case "required":
      return .required
    default:
      throw AdapterExecutionError(
        .policyBlocked,
        "\(environmentKey) must be one of off, auto, required (got '\(raw)')"
      )
    }
  }

  public static func mode(
    builderEnvironment: [String: String],
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> SeatbeltSandboxMode {
    if builderEnvironment[environmentKey] != nil {
      return try mode(environment: builderEnvironment)
    }
    return try mode(environment: processEnvironment)
  }
}

public func seatbeltArtifactRoot(environment: [String: String], workingDirectory: URL?) -> URL? {
  if let configured = environment["RIELA_ARTIFACT_DIR"], !configured.isEmpty {
    return URL(fileURLWithPath: configured, isDirectory: true)
  }
  guard let workingDirectory else {
    return nil
  }
  return workingDirectory.appendingPathComponent(".riela/artifacts", isDirectory: true)
}

public func localSandboxPolicy(
  for mode: AgentSandboxMode?,
  workingDirectory: URL?,
  artifactRoot: URL?,
  extraWritablePaths: [String] = [],
  enforcement: LocalProcessSandboxPolicy.Enforcement
) -> LocalProcessSandboxPolicy? {
  switch mode {
  case .readOnly:
    let writeScope: LocalProcessSandboxPolicy.FilesystemWriteScope =
      extraWritablePaths.isEmpty ? .readOnly : .paths(extraWritablePaths)
    return LocalProcessSandboxPolicy(enforcement: enforcement, writeScope: writeScope, networkAllowed: true)
  case .workspaceWrite:
    var writable: [String] = []
    if let workingDirectory {
      writable.append(workingDirectory.path)
    }
    if let artifactRoot {
      writable.append(artifactRoot.path)
    }
    writable.append(contentsOf: extraWritablePaths)
    return LocalProcessSandboxPolicy(enforcement: enforcement, writeScope: .paths(writable), networkAllowed: true)
  case .dangerFullAccess, nil:
    return nil
  }
}

public func resolveSeatbeltSandboxPolicy(
  builderEnvironment: [String: String],
  agentSandbox: AgentSandboxMode?,
  workingDirectory: URL?,
  stateRoots: [String]
) throws -> LocalProcessSandboxPolicy? {
  let mode = try SeatbeltSandboxSettings.mode(builderEnvironment: builderEnvironment)
  guard mode != .off else {
    return nil
  }
  let enforcement: LocalProcessSandboxPolicy.Enforcement = mode == .required ? .required : .auto
  return localSandboxPolicy(
    for: agentSandbox,
    workingDirectory: workingDirectory,
    artifactRoot: seatbeltArtifactRoot(environment: builderEnvironment, workingDirectory: workingDirectory),
    extraWritablePaths: stateRoots,
    enforcement: enforcement
  )
}

public func seatbeltProfile(
  for policy: LocalProcessSandboxPolicy,
  workingDirectory: URL?,
  temporaryDirectory: URL
) throws -> String {
  var lines: [String] = [
    "(version 1)",
    "(deny default)",
    "(allow process-fork)",
    "(allow process-exec)",
    "(allow signal (target same-sandbox))",
    "(allow sysctl-read)",
    "(allow mach-lookup)"
  ]

  if let readPaths = policy.readPaths {
    lines.append("(allow file-read-metadata)")
    var readRoots = readPaths
    if let workingDirectory {
      readRoots.append(workingDirectory.path)
    }
    for literal in try sortedSeatbeltLiterals(readRoots) {
      lines.append("(allow file-read* (subpath \"\(literal)\"))")
    }
  } else {
    lines.append("(allow file-read*)")
  }

  lines.append("(allow file-write-data (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))")
  lines.append("(allow file-ioctl (literal \"/dev/dtracehelper\"))")

  if case let .paths(roots) = policy.writeScope {
    var writable = roots
    writable.append(temporaryDirectory.path)
    writable.append("/private/tmp")
    for literal in try sortedSeatbeltLiterals(writable) {
      lines.append("(allow file-write* (subpath \"\(literal)\"))")
    }
  }

  lines.append(policy.networkAllowed ? "(allow network*)" : "(deny network*)")

  return lines.joined(separator: "\n") + "\n"
}

public func seatbeltInvocation(
  for configuration: LocalAgentProcessConfiguration,
  availability: SeatbeltAvailability = .live,
  temporaryDirectory: URL = FileManager.default.temporaryDirectory
) throws -> LocalAgentProcessConfiguration? {
  guard let policy = configuration.sandboxPolicy else {
    return nil
  }
  guard availability.isAvailable() else {
    switch policy.enforcement {
    case .auto:
      return configuration
    case .required:
      throw AdapterExecutionError(
        .policyBlocked,
        "\(SeatbeltSandboxSettings.environmentKey)=required but Seatbelt (\(SeatbeltAvailability.executablePath)) is unavailable on this platform"
      )
    }
  }

  let profile = try seatbeltProfile(
    for: policy,
    workingDirectory: configuration.workingDirectoryURL,
    temporaryDirectory: temporaryDirectory
  )
  var rewritten = configuration
  rewritten.executableURL = URL(fileURLWithPath: SeatbeltAvailability.executablePath)
  rewritten.arguments = ["-p", profile, configuration.executableURL.path] + configuration.arguments
  rewritten.sandboxPolicy = nil
  return rewritten
}

private func sortedSeatbeltLiterals(_ paths: [String]) throws -> [String] {
  var seen = Set<String>()
  var literals: [String] = []
  for path in paths {
    let canonical = canonicalizedSeatbeltPath(path)
    let literal = try seatbeltStringLiteral(canonical)
    if seen.insert(literal).inserted {
      literals.append(literal)
    }
  }
  return literals.sorted()
}

// Resolve every path to its physical location (e.g. /var -> /private/var,
// /tmp -> /private/tmp) so the generated subpaths match what the Seatbelt kernel
// evaluates after resolving symlinks. `URL.resolvingSymlinksInPath()` cannot be
// used because it strips the /private prefix, producing the opposite mapping.
private func canonicalizedSeatbeltPath(_ path: String) -> String {
  let expanded = (path as NSString).expandingTildeInPath
  let standardized = URL(fileURLWithPath: expanded).standardizedFileURL

  var existing = standardized
  var trailing: [String] = []
  while !FileManager.default.fileExists(atPath: existing.path) {
    let parent = existing.deletingLastPathComponent()
    if parent.path == existing.path {
      break
    }
    trailing.insert(existing.lastPathComponent, at: 0)
    existing = parent
  }

  var resolved = URL(fileURLWithPath: realpathString(existing.path) ?? existing.path)
  for component in trailing {
    resolved.appendPathComponent(component)
  }
  return resolved.path
}

private func realpathString(_ path: String) -> String? {
  guard let resolved = realpath(path, nil) else {
    return nil
  }
  defer { free(resolved) }
  return String(cString: resolved)
}

private func seatbeltStringLiteral(_ path: String) throws -> String {
  for scalar in path.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7f {
    throw AdapterExecutionError(
      .policyBlocked,
      "sandbox path contains control characters and cannot be embedded in a Seatbelt profile"
    )
  }
  var escaped = ""
  escaped.reserveCapacity(path.count)
  for character in path {
    if character == "\\" || character == "\"" {
      escaped.append("\\")
    }
    escaped.append(character)
  }
  return escaped
}
