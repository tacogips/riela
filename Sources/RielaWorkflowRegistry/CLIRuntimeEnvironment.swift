import Foundation

public enum CLIRuntimeEnvironment {
  @TaskLocal public static var overrides: [String: String]?

  public static func mergedProcessEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if let overrides {
      for (key, value) in overrides {
        environment[key] = value
      }
    }
    return environment
  }

  public static func homeDirectory(
    environment: [String: String] = mergedProcessEnvironment()
  ) -> String {
    environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
  }

  /// Relocates user-scope workflow storage (`workflows`, `packages`,
  /// `temporary-workflows`, `workflow-state`) away from `$HOME/.riela`, so a
  /// host such as RielaApp keeps its definitions apart from the CLI's.
  public static let workflowHomeEnvironmentName = "RIELA_WORKFLOW_HOME"

  /// The directory holding user-scope workflow storage: `$RIELA_WORKFLOW_HOME`
  /// when set, otherwise `$HOME/.riela`.
  public static func workflowHomeDirectory(
    environment: [String: String] = mergedProcessEnvironment()
  ) -> URL {
    let anchor = workflowHomeAnchor(environment: environment)
    return anchor.components.reduce(anchor.base) { $0.appendingPathComponent($1, isDirectory: true) }
  }

  /// Splits the workflow home into a base that may be reached through links and
  /// the components that registry roots open without following links.
  public static func workflowHomeAnchor(
    environment: [String: String] = mergedProcessEnvironment()
  ) -> (base: URL, components: [String]) {
    if let configured = environment[workflowHomeEnvironmentName], !configured.isEmpty {
      return (URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL, [])
    }
    return (URL(fileURLWithPath: homeDirectory(environment: environment), isDirectory: true), [".riela"])
  }
}
