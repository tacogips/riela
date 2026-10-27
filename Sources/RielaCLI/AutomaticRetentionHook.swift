import Foundation

enum AutomaticRetentionHook {
  private static let workflowRunArguments = ["workflow", "run"]
  private static let sessionCommands: Set<String> = ["resume", "rerun", "continue"]
  private static let helpArguments: Set<String> = ["--help", "-h"]
  private static let workingDirectoryOptions: Set<String> = ["--working-dir", "--working-directory"]

  static func applies(arguments: [String], exitCode: CLIExitCode, cancelled: Bool) -> Bool {
    guard exitCode != .usage, !cancelled, arguments.allSatisfy({ !helpArguments.contains($0) }) else {
      return false
    }
    if arguments.starts(with: workflowRunArguments) { return true }
    return arguments.count >= 2 && arguments[0] == "session" && sessionCommands.contains(arguments[1])
  }

  static func request(
    arguments: [String],
    environment: [String: String],
    currentDirectory: String
  ) -> RielaRetentionRequest {
    var workingDirectory: String?
    var sessionStore: String?
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if let (option, value) = splitOption(argument), workingDirectoryOptions.contains(option) {
        if !value.isEmpty { workingDirectory = value }
      } else if workingDirectoryOptions.contains(argument), index + 1 < arguments.count {
        index += 1
        workingDirectory = arguments[index]
      } else if argument.hasPrefix("--session-store=") {
        let value = String(argument.dropFirst("--session-store=".count))
        if !value.isEmpty { sessionStore = value }
      } else if argument == "--session-store", index + 1 < arguments.count {
        index += 1
        sessionStore = arguments[index]
      }
      index += 1
    }
    let projectPath = workingDirectory ?? currentDirectory
    let projectURL = URL(fileURLWithPath: projectPath, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
      .standardizedFileURL
    return RielaRetentionRequest(
      trigger: .automatic,
      homeDirectory: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true),
      projectDirectory: projectURL,
      explicitSessionStore: sessionStore,
      environment: environment,
      scope: .all
    )
  }

  static func runAutomaticPass(
    _ request: RielaRetentionRequest,
    service: RielaRetentionService = .init()
  ) -> [String] {
    do {
      let report = try service.run(request)
      return report.targets.compactMap { target in
        guard target.status == "failed" else { return nil }
        let detail = target.warnings.first ?? "retention pass failed for \(target.root)"
        return warning(detail)
      }
    } catch {
      return [warning(error.localizedDescription)]
    }
  }

  static func runIfApplicable(
    arguments: [String],
    exitCode: CLIExitCode,
    cancelled: Bool,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    service: RielaRetentionService = .init()
  ) -> [String] {
    guard applies(arguments: arguments, exitCode: exitCode, cancelled: cancelled) else { return [] }
    let retentionRequest = request(
      arguments: arguments,
      environment: environment,
      currentDirectory: FileManager.default.currentDirectoryPath
    )
    let retentionWarnings = runAutomaticPass(retentionRequest, service: service)
    let targets = RetentionTargetResolver.resolve(scope: retentionRequest.scope,
      homeDirectory: retentionRequest.homeDirectory, projectDirectory: retentionRequest.projectDirectory,
      explicitSessionStore: retentionRequest.explicitSessionStore, environment: retentionRequest.environment)
    let roots = targets.compactMap(\.sessionStoreRoot)
    return retentionWarnings + RunEndStorageMaintenance.run(sessionStoreRoots: roots)
  }

  private static func splitOption(_ argument: String) -> (String, String)? {
    guard let separator = argument.firstIndex(of: "=") else { return nil }
    return (String(argument[..<separator]), String(argument[argument.index(after: separator)...]))
  }

  private static func warning(_ detail: String) -> String {
    "riela retention warning: \(detail)"
  }
}
