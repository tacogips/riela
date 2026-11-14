import Foundation
import RielaCore

enum ContainerRuntimeKind: String, Equatable, Sendable {
  case appleContainer = "apple-container"
  case docker
  case podman
  case custom
}

protocol ContainerRuntimeDriver: Sendable {
  var kind: ContainerRuntimeKind { get }
  var executable: String { get }

  func buildArguments(image: String, containerfile: URL, contextDirectory: URL) -> [String]
  func runArguments(image: String, options: ContainerRuntimeRunOptions) -> [String]
}

struct ContainerRuntimeRunOptions: Equatable, Sendable {
  var environment: [String: String]
  var mounts: [ContainerRuntimeMount]
  var entrypoint: String?
  var workingDirectory: String?
  var networkAllowed: Bool
  var readOnlyRootFilesystem: Bool
}

struct ContainerRuntimeMount: Equatable, Sendable {
  var source: String
  var target: String
  var readOnly: Bool

  var volumeArgument: String {
    "\(source):\(target)\(readOnly ? ":ro" : "")"
  }

  var mountArgument: String {
    var components = [
      "type=bind",
      "source=\(source)",
      "target=\(target)"
    ]
    if readOnly {
      components.append("readonly")
    }
    return components.joined(separator: ",")
  }
}

struct AppleContainerDriver: ContainerRuntimeDriver {
  var executable: String

  var kind: ContainerRuntimeKind { .appleContainer }

  func runArguments(image: String, options: ContainerRuntimeRunOptions) -> [String] {
    var arguments = baseRunArguments(options: options, volumeFlag: "--mount") { mount in
      mount.mountArgument
    }
    if !options.networkAllowed {
      arguments += ["--network", "none", "--no-dns"]
    }
    arguments.append(image)
    return arguments
  }
}

struct DockerContainerDriver: ContainerRuntimeDriver {
  var executable: String

  var kind: ContainerRuntimeKind { .docker }
}

struct PodmanContainerDriver: ContainerRuntimeDriver {
  var executable: String

  var kind: ContainerRuntimeKind { .podman }
}

struct CustomContainerDriver: ContainerRuntimeDriver {
  var executable: String

  var kind: ContainerRuntimeKind { .custom }
}

extension ContainerRuntimeDriver {
  func buildArguments(image: String, containerfile: URL, contextDirectory: URL) -> [String] {
    ["build", "-t", image, "-f", containerfile.path, contextDirectory.path]
  }

  func runArguments(image: String, options: ContainerRuntimeRunOptions) -> [String] {
    var arguments = baseRunArguments(options: options, volumeFlag: "-v") { mount in
      mount.volumeArgument
    }
    if !options.networkAllowed {
      arguments += ["--network", "none"]
    }
    arguments.append(image)
    return arguments
  }

  func baseRunArguments(
    options: ContainerRuntimeRunOptions,
    volumeFlag: String,
    renderMount: (ContainerRuntimeMount) -> String
  ) -> [String] {
    var arguments = ["run", "--rm", "-i"]
    if options.readOnlyRootFilesystem {
      arguments.append("--read-only")
      arguments += ["--tmpfs", "/tmp"]
    }
    for key in options.environment.keys.sorted() {
      arguments += ["-e", "\(key)=\(options.environment[key] ?? "")"]
    }
    for mount in options.mounts.sorted(by: { $0.volumeArgument < $1.volumeArgument }) {
      arguments += [volumeFlag, renderMount(mount)]
    }
    if let entrypoint = options.entrypoint?.trimmingCharacters(in: .whitespacesAndNewlines), !entrypoint.isEmpty {
      arguments += ["--entrypoint", entrypoint]
    }
    if let workingDirectory = options.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
      !workingDirectory.isEmpty {
      arguments += ["-w", workingDirectory]
    }
    return arguments
  }
}

struct ContainerRuntimeDiscovery {
  private static let runtimeEnvironmentKey = "RIELA_CONTAINER_RUNTIME"
  private static let defaultSearchPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  private static let preferredRuntimeCommands = ["container", "docker", "podman"]

  var environment: [String: String]
  var fileManager: FileManager
  var hostPlatform: RielaHostPlatform

  init(
    environment: [String: String],
    fileManager: FileManager = .default,
    hostPlatform: RielaHostPlatform = .current
  ) {
    self.environment = environment
    self.fileManager = fileManager
    self.hostPlatform = hostPlatform
  }

  func selectedDriver() -> any ContainerRuntimeDriver {
    if let configured = configuredDriver() {
      return configured
    }
    return selectedAvailableDriver() ?? DockerContainerDriver(executable: "docker")
  }

  func configuredDriver() -> (any ContainerRuntimeDriver)? {
    guard let configured = environment[Self.runtimeEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !configured.isEmpty else {
      return nil
    }
    return driver(for: configured)
  }

  var configuredAppleContainerIsUnsupported: Bool {
    guard hostPlatform != .darwin,
          let configured = environment[Self.runtimeEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !configured.isEmpty else {
      return false
    }
    return runtimeCommandName(for: configured) == "container"
  }

  func selectedAvailableDriver() -> (any ContainerRuntimeDriver)? {
    for command in Self.preferredRuntimeCommands {
      guard let resolvedExecutable = resolvedExecutable(command) else {
        continue
      }
      let executable = command == "container" ? resolvedExecutable : command
      guard let driver = driver(for: executable) else {
        continue
      }
      return driver
    }
    return nil
  }

  private func driver(for executable: String) -> (any ContainerRuntimeDriver)? {
    switch runtimeCommandName(for: executable) {
    case "container":
      guard hostPlatform == .darwin else {
        return nil
      }
      return AppleContainerDriver(executable: nativeAppleContainerExecutable(executable))
    case "docker":
      return DockerContainerDriver(executable: executable)
    case "podman":
      return PodmanContainerDriver(executable: executable)
    default:
      return CustomContainerDriver(executable: executable)
    }
  }

  private func runtimeCommandName(for executable: String) -> String {
    URL(fileURLWithPath: executable).lastPathComponent
  }

  private func nativeAppleContainerExecutable(_ executable: String) -> String {
    if executable.hasPrefix("/") {
      return executable
    }
    return resolvedExecutable(executable) ?? "/usr/local/bin/container"
  }

  private func resolvedExecutable(_ command: String) -> String? {
    let path = environment["PATH"] ?? Self.defaultSearchPath
    for directory in path.split(separator: ":").map(String.init) {
      let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(command).path
      if fileManager.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}
