#if os(macOS)
import Foundation

public struct RielaAppLaunchOptions: Equatable, Sendable {
  public struct InitialViewer: Equatable, Sendable {
    public var workflowPath: String
    public var sessionStoreRoot: String?

    public init(workflowPath: String, sessionStoreRoot: String? = nil) {
      self.workflowPath = workflowPath
      self.sessionStoreRoot = sessionStoreRoot
    }
  }

  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectory: String

  public init(
    arguments: [String],
    environment: [String: String],
    workingDirectory: String = FileManager.default.currentDirectoryPath
  ) {
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
  }

  public static func current() -> RielaAppLaunchOptions {
    RielaAppLaunchOptions(
      arguments: Array(CommandLine.arguments.dropFirst()),
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: FileManager.default.currentDirectoryPath
    )
  }

  public var profileName: RielaAppProfileName? {
    value(flag: "--profile").map(RielaAppProfileName.init)
  }

  public var projectRoot: URL? {
    value(flag: "--project-root").map { absoluteURL($0, isDirectory: true) }
  }

  public var appRoot: URL? {
    configuredPath(flag: "--app-root", environmentName: "RIELA_APP_ROOT")
      .map { absoluteURL($0, isDirectory: true) }
  }

  public var importSources: [URL] {
    values(flag: "--import-workflow-or-package").map { absoluteURL($0) }
  }

  public var opensWorkflows: Bool {
    arguments.contains("--open-workflows")
  }

  public var autostartsDaemonWorkflows: Bool {
    !arguments.contains("--no-autostart-daemons")
  }

  public var initialViewer: InitialViewer? {
    guard let workflowPath = value(flag: "--open-viewer") else {
      return nil
    }
    return InitialViewer(
      workflowPath: absolutePath(workflowPath, isDirectory: true),
      sessionStoreRoot: value(flag: "--session-store-root").map { absolutePath($0, isDirectory: true) }
    )
  }

  public func homeDirectory(defaultHome: String) -> URL {
    if let path = configuredPath(flag: "--home-root", environmentName: "RIELA_APP_HOME")
      ?? environment["HOME"].flatMap({ $0.isEmpty ? nil : $0 }) {
      return absoluteURL(path, isDirectory: true)
    }
    return absoluteURL(defaultHome, isDirectory: true)
  }

  private func configuredPath(flag: String, environmentName: String) -> String? {
    value(flag: flag) ?? environment[environmentName].flatMap { $0.isEmpty ? nil : $0 }
  }

  private func value(flag: String) -> String? {
    values(flag: flag).last
  }

  private func values(flag: String) -> [String] {
    var results: [String] = []
    for (index, argument) in arguments.enumerated() {
      if argument == flag, arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") {
        results.append(arguments[index + 1])
      } else if argument.hasPrefix("\(flag)=") {
        results.append(String(argument.dropFirst("\(flag)=".count)))
      }
    }
    return results.filter { !$0.isEmpty }
  }

  private func absolutePath(_ rawPath: String, isDirectory: Bool = false) -> String {
    absoluteURL(rawPath, isDirectory: isDirectory).path
  }

  private func absoluteURL(_ rawPath: String, isDirectory: Bool = false) -> URL {
    if rawPath.hasPrefix("/") {
      return URL(fileURLWithPath: rawPath, isDirectory: isDirectory).standardizedFileURL
    }
    return URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .standardizedFileURL
      .appendingPathComponent(rawPath, isDirectory: isDirectory)
      .standardizedFileURL
  }
}
#endif
