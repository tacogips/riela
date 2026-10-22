import Foundation
import RielaAdapters
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One private, owner-only HOME and temporary tree. Keep this alive until the
/// process runner has reaped the worker and its owned foreground children.
final class SandboxExecutionDirectory: Sendable {
  let root: URL
  private let resources = SandboxExecutionResources()

  init(parent: URL = FileManager.default.temporaryDirectory) throws {
    let candidate = parent.appendingPathComponent("riela-sandbox-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard let physical = realpath(candidate.path, nil) else {
      try? FileManager.default.removeItem(at: candidate)
      throw AdapterExecutionError(.policyBlocked, "private sandbox directory could not be prepared")
    }
    root = URL(fileURLWithPath: String(cString: physical))
    free(physical)
    for name in ["home", "tmp"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func retain(_ projection: SandboxCredentialProjection) { resources.retain(projection) }
}

private final class SandboxExecutionResources: @unchecked Sendable {
  private let lock = NSLock()
  private var projections: [SandboxCredentialProjection] = []
  func retain(_ projection: SandboxCredentialProjection) { lock.withLock { projections.append(projection) } }
}

struct ExecutionSandboxLauncher: Sendable {
  var environment: [String: String]
  var hostPlatform: RielaHostPlatform = .current

  func process(executable: URL, arguments: [String], workspace: URL, options: WorkflowExecutionSandbox,
               directory: SandboxExecutionDirectory, explicitEnvironment: [String: String] = [:],
               containerExecutable: String? = nil, homeDirectory: URL? = nil,
               runtimeEnvironment: [String: String] = [:]) throws -> LocalProcessConfiguration {
    try options.validate()
    guard workspace.resolvingSymlinksInPath().standardizedFileURL.path != "/" else {
      throw AdapterExecutionError(.policyBlocked, "sandbox workspace cannot be the filesystem root")
    }
    guard runtimeEnvironment.keys.allSatisfy({ $0 == "RIELA_ADDON_STATE_DIR" }) else {
      throw AdapterExecutionError(.policyBlocked, "invalid sandbox runtime environment binding")
    }
    let home = homeDirectory ?? directory.root.appendingPathComponent("home")
    var preparedOptions = options
    if !options.credentials.isEmpty {
      let extraWritable = (options.container?.mounts ?? []).filter { !$0.readOnly }.map {
        $0.source.hasPrefix("/") ? URL(fileURLWithPath: $0.source) : workspace.appendingPathComponent($0.source)
      }
      let projection = try SandboxCredentialProjection(credentials: options.credentials, parent: directory.root.deletingLastPathComponent(),
        writableRoots: [workspace, directory.root, home] + options.writePaths.map { URL(fileURLWithPath: $0) } + extraWritable)
      try projection.install(in: home)
      directory.retain(projection)
      preparedOptions.credentials = []
      preparedOptions.credentialPaths.append(projection.root.path)
    }
    var childEnvironment: [String: String] = [:]
    let defaultNames = options.backend == .container
      ? ["LANG", "LC_ALL", "LC_CTYPE", "TZ"] : ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ"]
    for name in defaultNames + options.environment {
      if let value = environment[name] { childEnvironment[name] = value }
    }
    if options.backend != .container {
      childEnvironment["PATH"] = childEnvironment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    for (name, value) in explicitEnvironment {
      guard isValidEnvironmentVariableName(name), !WorkflowExecutionSandbox.reservedEnvironment.contains(name),
            !name.hasPrefix("LD_"), !name.hasPrefix("DYLD_") else {
        throw AdapterExecutionError(.policyBlocked, "sandbox explicit environment includes a runtime-owned or loader variable")
      }
      childEnvironment[name] = value
    }
    var configuration = LocalProcessConfiguration(executableURL: executable, arguments: arguments,
      environment: childEnvironment, workingDirectoryURL: workspace, inheritEnvironment: false)
    if options.backend != .container {
      var native = try NativeProcessSandbox().invocation(for: configuration, options: preparedOptions,
        stateDirectory: directory.root, homeDirectory: home)
      native.environment.merge(runtimeEnvironment) { _, owned in owned }
      return native
    }
    configuration.environment.merge(runtimeEnvironment) { _, owned in owned }
    return try containerProcess(configuration, options: preparedOptions, directory: directory,
      executable: containerExecutable ?? executable.path, home: home)
  }

  private func containerProcess(_ configuration: LocalProcessConfiguration, options: WorkflowExecutionSandbox,
                                directory: SandboxExecutionDirectory, executable: String, home: URL) throws -> LocalProcessConfiguration {
    let settings = options.container ?? .init()
    var selectedEnvironment = environment
    if selectedEnvironment["RIELA_CONTAINER_RUNTIME"]?.isEmpty != false, settings.runtime != .auto {
      selectedEnvironment["RIELA_CONTAINER_RUNTIME"] = settings.runtime == .appleContainer ? "container" : settings.runtime.rawValue
    }
    let discovery = ContainerRuntimeDiscovery(environment: selectedEnvironment, hostPlatform: hostPlatform)
    guard !discovery.configuredAppleContainerIsUnsupported,
          let driver = discovery.configuredDriver() ?? discovery.selectedAvailableDriver(),
          let workspace = configuration.workingDirectoryURL else {
      throw AdapterExecutionError(.policyBlocked, "selected container sandbox runtime is unavailable")
    }
    var mounts = options.ephemeralHome ? [] : [ContainerRuntimeMount(source: workspace.path, target: workspace.path, readOnly: false),
      .init(source: directory.root.path, target: directory.root.path, readOnly: false)]
    if !options.ephemeralHome, home.path != directory.root.appendingPathComponent("home").path {
      mounts.append(.init(source: home.path, target: home.path, readOnly: false))
    }
    mounts += options.readPaths.map { .init(source: $0, target: $0, readOnly: true) }
    mounts += options.writePaths.map { .init(source: $0, target: $0, readOnly: false) }
    mounts += settings.mounts.map { mount in
      let source = mount.source.hasPrefix("/") ? URL(fileURLWithPath: mount.source) : workspace.appendingPathComponent(mount.source)
      return .init(source: source.resolvingSymlinksInPath().standardizedFileURL.path, target: mount.target, readOnly: mount.readOnly)
    }
    let writable = mounts.filter { !$0.readOnly }.map { URL(fileURLWithPath: $0.source).resolvingSymlinksInPath().path }
    for credential in options.credentialPaths {
      let source = URL(fileURLWithPath: credential).resolvingSymlinksInPath().path
      guard !writable.contains(where: { Self.overlaps(source, $0) }) else {
        throw AdapterExecutionError(.policyBlocked, "host credentials overlap writable container storage")
      }
      mounts.append(.init(source: source, target: credential, readOnly: true))
    }
    var targets = Set<String>()
    for mount in mounts {
      var isDirectory: ObjCBool = false
      guard URL(fileURLWithPath: mount.source).resolvingSymlinksInPath().standardizedFileURL.path != "/",
            URL(fileURLWithPath: mount.target).standardizedFileURL.path != "/", !mount.source.contains(","), !mount.source.contains(":"), !mount.target.contains(","),
            !mount.target.contains(":"), targets.insert(mount.target).inserted,
            FileManager.default.fileExists(atPath: mount.source, isDirectory: &isDirectory),
            driver.kind != .appleContainer || isDirectory.boolValue else {
        throw AdapterExecutionError(.policyBlocked, "sandbox mounts must exist and be distinct; Apple Container requires directory sources")
      }
    }
    var childEnvironment = configuration.environment
    childEnvironment["HOME"] = options.ephemeralHome ? "/tmp/riela-private-\(UUID().uuidString)/home" : home.path
    childEnvironment["TMPDIR"] = options.ephemeralHome ? "/tmp" : directory.root.appendingPathComponent("tmp").path
    let arguments = driver.runArguments(image: settings.image, options: .init(environment: childEnvironment, mounts: mounts,
      entrypoint: executable, workingDirectory: options.ephemeralHome ? "/tmp" : workspace.path,
      networkAllowed: options.networkPolicy == .egressAllowed,
      readOnlyRootFilesystem: true, disablePersistentLogs: options.ephemeralHome)) + configuration.arguments
    let runtimeEnvironment = environment.filter { options.credentialEnvironment[$0.key] == nil }
    return .init(executableURL: URL(fileURLWithPath: driver.executable.hasPrefix("/") ? driver.executable : "/usr/bin/env"),
      arguments: driver.executable.hasPrefix("/") ? arguments : [driver.executable] + arguments,
      environment: runtimeEnvironment, workingDirectoryURL: workspace, inheritEnvironment: false)
  }

  private static func overlaps(_ left: String, _ right: String) -> Bool {
    left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
  }

  func workerExecutable() throws -> URL {
    if let configured = environment["RIELA_SANDBOX_WORKER_EXECUTABLE"] {
      guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else {
        throw AdapterExecutionError(.policyBlocked, "configured Riela sandbox worker executable is unavailable")
      }
      return URL(fileURLWithPath: configured).resolvingSymlinksInPath()
    }
    if let executable = Bundle.main.executableURL, executable.lastPathComponent == "riela" { return executable.resolvingSymlinksInPath() }
    for path in (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
      let executable = URL(fileURLWithPath: String(path)).appendingPathComponent("riela")
      if FileManager.default.isExecutableFile(atPath: executable.path) { return executable.resolvingSymlinksInPath() }
    }
    throw AdapterExecutionError(.policyBlocked, "Riela CLI executable is required for an isolated Swift worker")
  }

  func workerOptions(_ options: WorkflowExecutionSandbox, executable: URL) throws -> WorkflowExecutionSandbox {
    var result = options
    if options.backend != .container {
      let siblings = try FileManager.default.contentsOfDirectory(at: executable.deletingLastPathComponent(), includingPropertiesForKeys: nil)
      result.readPaths += siblings.filter { $0.pathExtension == "resources" }.map(\.path)
    }
    return result
  }
}
