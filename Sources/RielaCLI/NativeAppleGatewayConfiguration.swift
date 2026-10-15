import Foundation
import RielaCore
#if canImport(AppleGatewayCore)
import AppleGatewayCore
#endif

/// Guest configuration may tune request limits, but cannot select host files,
/// executables, or service storage. The host's private configuration owns those.
enum NativeAppleGatewayConfiguration {
  static func validate(arguments: [String], environment: [String: String], exposedRoots: [URL]) throws {
    guard arguments.first != "config", arguments.first != "schema", arguments.first != "permissions" else { return }
    #if canImport(AppleGatewayCore)
    let environment = sanitizedGatewayEnvironment(runtimeEnvironment: environment, bindings: [:])
    let resolver = AppleGatewayConfigResolver()
    let trusted = try resolver.resolve(environment: environment)
    try requirePrivate(trusted.source.path, exposedRoots: exposedRoots)
    try requirePrivate(trusted.config.storage.cacheDir, exposedRoots: exposedRoots)
    if !trusted.config.notifications.helperAppPath.isEmpty {
      try requirePrivate(trusted.config.notifications.helperAppPath, exposedRoots: exposedRoots)
    }
    // Flags have already been capability-checked and file inputs snapshotted.
    // Parse only option positions; a query or opaque key can equal a flag.
    var index = 0
    var configPath: String?
    let valueOptions: Set<String> = ["--config", "--query", "--variables", "--key", "--output-dir", "--role", "--domain"]
    while index < arguments.count {
      if valueOptions.contains(arguments[index]), index + 1 < arguments.count {
        if arguments[index] == "--config" { configPath = arguments[index + 1] }
        index += 2
      } else { index += 1 }
    }
    guard let configPath else { return }
    let supplied = try resolver.resolve(cliConfigPath: configPath, environment: environment).config
    guard supplied.storage == trusted.config.storage, supplied.mail == trusted.config.mail,
          supplied.notifications == trusted.config.notifications, supplied.domains == trusted.config.domains,
          supplied.phoneCalls == trusted.config.phoneCalls else { throw denied() }
    #else
    throw denied()
    #endif
  }

  private static func requirePrivate(_ path: String, exposedRoots: [URL]) throws {
    guard path.hasPrefix("/") else { throw denied() }
    let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    for root in exposedRoots {
      let root = root.resolvingSymlinksInPath().standardizedFileURL.path
      guard candidate != root, !candidate.hasPrefix(root == "/" ? root : root + "/"),
            !root.hasPrefix(candidate == "/" ? candidate : candidate + "/") else { throw denied() }
    }
  }

  private static func denied() -> AdapterExecutionError {
    .init(.policyBlocked, "native Apple service configuration and storage must remain host-owned and outside guest shares")
  }
}
