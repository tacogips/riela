import Foundation
import RielaCore
import RielaWorkflowRegistry

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
    RielaAutomaticStoragePass.runScheduled(request, service: service)
  }

  fileprivate static func runAutomaticPassWithReport(
    _ request: RielaRetentionRequest,
    service: RielaRetentionService
  ) -> [String] {
    do {
      let report = try service.run(request)
      let warnings: [String] = report.targets.compactMap { target in
        guard target.status == "failed" else { return nil }
        let detail = target.warnings.first ?? "retention pass failed for \(target.root)"
        return warning(detail)
      }
      return warnings
    } catch {
      return [warning(error.localizedDescription)]
    }
  }

  static func runIfApplicable(
    arguments: [String],
    exitCode: CLIExitCode,
    cancelled: Bool,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    service: RielaRetentionService = .init(),
    currentDirectory: String = FileManager.default.currentDirectoryPath
  ) -> [String] {
    guard applies(arguments: arguments, exitCode: exitCode, cancelled: cancelled) else { return [] }
    let retentionRequest = request(
      arguments: arguments,
      environment: environment,
      currentDirectory: currentDirectory
    )
    let targets = RetentionTargetResolver.resolve(scope: retentionRequest.scope,
      homeDirectory: retentionRequest.homeDirectory, projectDirectory: retentionRequest.projectDirectory,
      explicitSessionStore: retentionRequest.explicitSessionStore, environment: retentionRequest.environment)
    let explicit = [retentionRequest.explicitSessionStore, retentionRequest.environment["RIELA_SESSION_STORE"]]
      .compactMap { $0 }.first { !$0.isEmpty }
    let selectedTarget = selectedSessionStoreRoot(arguments: arguments, targets: targets,
      explicitStore: explicit, projectDirectory: retentionRequest.projectDirectory)
    let warnings = runAutomaticPassWithReport(retentionRequest, service: service)
    guard let config = try? RielaRetentionConfiguration.load(homeDirectory: retentionRequest.homeDirectory,
      projectDirectory: retentionRequest.projectDirectory, environment: retentionRequest.environment),
      let target = selectedTarget, config.effectivePolicy(for: target.kind).policy.automatic else { return warnings }
    return warnings + RunEndStorageMaintenance.run(targets: [target], profile: .runEnd)
  }

  private static func splitOption(_ argument: String) -> (String, String)? {
    guard let separator = argument.firstIndex(of: "=") else { return nil }
    return (String(argument[..<separator]), String(argument[argument.index(after: separator)...]))
  }

  private static func warning(_ detail: String) -> String {
    "riela retention warning: \(detail)"
  }

  private static func optionValue(_ name: String, in arguments: [String]) -> String? {
    for (index, argument) in arguments.enumerated() {
      if argument == name, arguments.indices.contains(index + 1) { return arguments[index + 1] }
      if argument.hasPrefix(name + "=") { return String(argument.dropFirst(name.count + 1)) }
    }
    return nil
  }

  private static func selectedSessionStoreRoot(
    arguments: [String],
    targets: [RetentionTarget],
    explicitStore: String?,
    projectDirectory: URL?
  ) -> RetentionTarget? {
    if let explicitStore {
      let base = projectDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let path = URL(fileURLWithPath: explicitStore, relativeTo: base).standardizedFileURL.path
      return targets.first { $0.sessionStoreRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path }
    }
    if arguments.count >= 2, arguments[0] == "session", sessionCommands.contains(arguments[1]) {
      let kind: RielaRetentionTargetKind = optionValue("--scope", in: arguments) == "user" ? .user : .project
      return targets.first(where: { $0.kind == kind })
    }
    guard arguments.starts(with: workflowRunArguments), arguments.count > 2 else { return nil }
    let workingDirectory = optionValue("--working-dir", in: arguments)
      ?? optionValue("--working-directory", in: arguments)
      ?? FileManager.default.currentDirectoryPath
    let requestedScope = optionValue("--scope", in: arguments).flatMap(WorkflowScope.init(rawValue:)) ?? .auto
    let scope: WorkflowScope
    if requestedScope == .auto {
      let resolution = WorkflowResolutionOptions(
        workflowName: arguments[2],
        scope: .auto,
        workflowDefinitionDir: optionValue("--workflow-definition-dir", in: arguments),
        workingDirectory: workingDirectory
      )
      guard let bundle = try? FileSystemWorkflowBundleResolver().resolve(resolution) else { return nil }
      scope = bundle.sourceScope
    } else {
      scope = requestedScope
    }
    let kind: RielaRetentionTargetKind = scope == .user ? .user : .project
    return targets.first(where: { $0.kind == kind })
  }
}

public enum RielaAutomaticStoragePass {
  public static func runScheduled(_ request: RielaRetentionRequest) -> [String] {
    runScheduled(request, service: .init())
  }

  static func runScheduled(_ request: RielaRetentionRequest, service: RielaRetentionService) -> [String] {
    let warnings = AutomaticRetentionHook.runAutomaticPassWithReport(request, service: service)
    guard let config = try? RielaRetentionConfiguration.load(homeDirectory: request.homeDirectory,
      projectDirectory: request.projectDirectory, environment: request.environment) else { return warnings }
    let targets = RetentionTargetResolver.resolve(scope: request.scope, homeDirectory: request.homeDirectory,
      projectDirectory: request.projectDirectory, explicitSessionStore: request.explicitSessionStore,
      environment: request.environment).filter { config.effectivePolicy(for: $0.kind).policy.automatic }
    return warnings + RunEndStorageMaintenance.run(targets: targets, profile: .scheduled)
  }
}
