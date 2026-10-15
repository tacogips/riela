import Foundation
import RielaCore

public enum NativeSandboxHostPlatform: Equatable, Sendable {
  case darwin
  case linux
  case unsupported

  public static var current: Self {
    #if os(macOS)
    .darwin
    #elseif os(Linux)
    .linux
    #else
    .unsupported
    #endif
  }
}

/// Strict native isolation. Unlike the legacy optional Seatbelt wrapper, a
/// selected backend is mandatory and ambient process variables never propagate.
public struct NativeProcessSandbox: Sendable {
  public var hostPlatform: NativeSandboxHostPlatform
  public var isExecutable: @Sendable (String) -> Bool

  public init(hostPlatform: NativeSandboxHostPlatform = .current,
              isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
    self.hostPlatform = hostPlatform
    self.isExecutable = isExecutable
  }

  public func selectedBackend(_ options: WorkflowExecutionSandbox) throws -> WorkflowSandboxBackend {
    try options.validate()
    if options.backend == .auto {
      switch hostPlatform {
      case .darwin: return .seatbelt
      case .linux: return .bubblewrap
      default: throw denied("native execution sandbox is unsupported on this host")
      }
    }
    return options.backend
  }

  public func invocation(for configuration: LocalProcessConfiguration, options: WorkflowExecutionSandbox,
                         stateDirectory: URL, homeDirectory: URL? = nil) throws -> LocalProcessConfiguration {
    guard let workspace = configuration.workingDirectoryURL else { throw denied("sandbox requires a working directory") }
    let backend = try selectedBackend(options)
    let home = homeDirectory ?? stateDirectory.appendingPathComponent("home")
    let paths = try NativeSandboxPaths(configuration: configuration, options: options, stateDirectory: stateDirectory, homeDirectory: home,
      workspace: workspace, hostPlatform: hostPlatform)
    var result = configuration
    result.sandboxPolicy = nil
    result.inheritEnvironment = false
    result.environment = configuration.environment
    for key in result.environment.keys {
      guard !WorkflowExecutionSandbox.reservedEnvironment.contains(key), !key.hasPrefix("LD_"), !key.hasPrefix("DYLD_") else {
        throw denied("sandbox environment cannot override loader or runtime-owned variables")
      }
    }
    result.environment["HOME"] = home.path
    result.environment["TMPDIR"] = stateDirectory.appendingPathComponent("tmp").path
    result.environment["TMP"] = result.environment["TMPDIR"]
    result.environment["TEMP"] = result.environment["TMPDIR"]
    switch backend {
    case .seatbelt:
      guard hostPlatform == .darwin, isExecutable(SeatbeltAvailability.executablePath) else {
        throw denied("selected Seatbelt backend requires macOS and /usr/bin/sandbox-exec")
      }
      result.executableURL = URL(fileURLWithPath: SeatbeltAvailability.executablePath)
      result.arguments = ["-p", try paths.seatbeltProfile(networkAllowed: options.networkPolicy == .egressAllowed),
        configuration.executableURL.path] + configuration.arguments
    case .bubblewrap:
      guard hostPlatform == .linux, let executable = ["/usr/bin/bwrap", "/bin/bwrap"].first(where: isExecutable) else {
        throw denied("selected bubblewrap backend requires Linux, bwrap, and enabled unprivileged user namespaces")
      }
      let filter = stateDirectory.appendingPathComponent("socket-filter-" + UUID().uuidString + ".bpf")
      try NativeSandboxSeccomp.socketFilter().write(to: filter, options: .withoutOverwriting)
      result.executableURL = URL(fileURLWithPath: "/bin/sh")
      // Fixed host-side launcher: no user text is evaluated as shell syntax.
      // bwrap consumes fd 3 before starting the guest; no host socket survives.
      result.arguments = ["-c", "filter=$1; shift; exec \"$@\" 3<\"$filter\"", "riela-bwrap", filter.path, executable]
        + paths.bubblewrapArguments(networkAllowed: options.networkPolicy == .egressAllowed)
        + ["--seccomp", "3", "--", configuration.executableURL.path] + configuration.arguments
    case .auto, .container:
      throw denied("container isolation must use the container execution launcher")
    }
    return result
  }

  private func denied(_ message: String) -> AdapterExecutionError { .init(.policyBlocked, message) }
}

struct NativeSandboxPaths {
  var reads: [String]
  var writes: [String]
  var credentials: [String]
  var workspace: String
  var systemReadAliases: [String: String]

  init(configuration: LocalProcessConfiguration, options: WorkflowExecutionSandbox, stateDirectory: URL, homeDirectory: URL,
       workspace: URL, hostPlatform: NativeSandboxHostPlatform) throws {
    self.workspace = try Self.approvedPath(workspace.path)
    let systemReads = hostPlatform == .darwin
      ? ["/System", "/usr", "/bin", "/sbin", "/Library/Apple", "/private/etc", "/private/var/db/timezone", "/dev/null", "/dev/random", "/dev/urandom", "/dev/fd"]
      : ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc/ssl", "/etc/hosts", "/etc/resolv.conf", "/etc/nsswitch.conf", "/etc/localtime", "/etc/passwd", "/etc/group"]
    systemReadAliases = Dictionary(uniqueKeysWithValues: systemReads.compactMap { path in
      let physical = Self.physical(path)
      guard physical != path, FileManager.default.fileExists(atPath: physical) else { return nil }
      return (path, physical)
    })
    credentials = Array(Set(options.credentialPaths.map(Self.physical))).sorted()
    writes = try Array(Set(([self.workspace, stateDirectory.path, homeDirectory.path] + options.writePaths).map(Self.approvedPath))).sorted()
    for source in options.credentialPaths {
      guard !writes.contains(where: { Self.overlaps(Self.systemAliasPath(source), $0) }) else {
        throw AdapterExecutionError(.policyBlocked, "credential paths cannot originate in guest-writable storage")
      }
    }
    for credential in credentials {
      guard FileManager.default.fileExists(atPath: credential), !writes.contains(where: { Self.overlaps($0, credential) }) else {
        throw AdapterExecutionError(.policyBlocked, "host credentials must exist outside all writable sandbox roots")
      }
    }
    let explicitReads = try options.readPaths.map(Self.approvedPath)
    reads = Array(Set((systemReads + explicitReads + credentials + [configuration.executableURL.path])
      .map(Self.physical).filter { FileManager.default.fileExists(atPath: $0) })).sorted()
    for path in writes + reads where path == "/" {
      throw AdapterExecutionError(.policyBlocked, "sandbox cannot share the filesystem root")
    }
  }

  func seatbeltProfile(networkAllowed: Bool) throws -> String {
    var lines = ["(version 1)", "(deny default)", "(allow process-fork)", "(allow process-exec)",
      "(allow signal (target same-sandbox))", "(allow sysctl-read)", "(allow file-read-metadata)"]
    // macOS libc opens / during startup and traverses ancestors for getcwd.
    // Permit directory entries at those exact paths, never their file content.
    var ancestors = Set(["/"])
    for root in reads + writes {
      var parent = URL(fileURLWithPath: root).deletingLastPathComponent()
      while parent.path != "/" {
        ancestors.insert(Self.physical(parent.path))
        parent.deleteLastPathComponent()
      }
    }
    for path in ancestors.sorted() { lines.append("(allow file-read-data (literal \(try literal(path))))") }
    for path in Array(Set(reads + writes)).sorted() { lines.append("(allow file-read* (subpath \(try literal(path))))") }
    for path in writes { lines.append("(allow file-write* (subpath \(try literal(path))))") }
    for path in credentials { lines.append("(deny file-write* (subpath \(try literal(path))))") }
    lines.append("(allow file-write-data (literal \"/dev/null\"))")
    if networkAllowed {
      lines += ["(allow network-outbound (remote ip))",
        "(allow network-outbound (literal \"/private/var/run/mDNSResponder\"))",
        "(allow mach-lookup (global-name \"com.apple.trustd.agent\") (global-name \"com.apple.SystemConfiguration.configd\"))"]
    }
    return lines.joined(separator: "\n") + "\n"
  }

  func bubblewrapArguments(networkAllowed: Bool) -> [String] {
    var arguments = ["--die-with-parent", "--new-session", "--unshare-all", "--unshare-user",
      "--disable-userns", "--assert-userns-disabled", "--cap-drop", "ALL"]
    if networkAllowed { arguments.append("--share-net") }
    arguments += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]
    for path in reads { arguments += ["--ro-bind", path, path] }
    // An empty root must retain /bin, /lib and resolver/zoneinfo aliases.
    // Mount their approved physical source at the system spelling too; this
    // exposes the same read-only files, without sharing another host root.
    for path in systemReadAliases.keys.sorted() {
      if let physical = systemReadAliases[path] { arguments += ["--ro-bind", physical, path] }
    }
    for path in writes { arguments += ["--bind", path, path] }
    for path in credentials { arguments += ["--ro-bind", path, path] }
    arguments += ["--chdir", workspace]
    return arguments
  }

  private func literal(_ path: String) throws -> String {
    guard !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
      throw AdapterExecutionError(.policyBlocked, "sandbox path contains control characters")
    }
    return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  static func physical(_ path: String) -> String {
    // Foundation normalizes /private/var back to /var on macOS. Seatbelt
    // evaluates physical paths, so retain realpath's spelling instead.
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return nativeSandboxPhysicalPath(url)
  }

  static func overlaps(_ left: String, _ right: String) -> Bool {
    left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
  }

  private static func approvedPath(_ path: String) throws -> String {
    let expected = systemAliasPath(path)
    guard physical(path) == expected else {
      throw AdapterExecutionError(.policyBlocked, "sandbox shares cannot traverse user-controlled symlinks; specify a physical path")
    }
    return expected
  }

  private static func systemAliasPath(_ path: String) -> String {
    let path = URL(fileURLWithPath: path).standardizedFileURL.path
    #if os(macOS)
    for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
      return "/private" + path
    }
    #endif
    return path
  }
}
