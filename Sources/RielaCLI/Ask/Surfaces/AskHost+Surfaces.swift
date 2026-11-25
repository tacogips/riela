import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL

extension AskHost {
  static func local(
    workingDirectory: String, sessionStore: String?, scope: WorkflowScope, environment: [String: String],
    settings: RielaAppAssistantSettings? = nil, console: (any GraphQLConsoleProviding)? = nil,
    sessions: (any GraphQLSessionControlProviding)? = nil,
    rielaExecutablePath: String? = Bundle.main.executableURL?.resolvingSymlinksInPath().path
  ) -> AskHost {
    let root = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: sessionStore, scope: scope, workingDirectory: workingDirectory, environment: environment
    )
    let readers = AskReadProviders.local(
      workingDirectory: workingDirectory, sessionStore: root, scope: scope, environment: environment, console: console
    )
    return AskHost(
      sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: root), workingDirectory: workingDirectory,
      scratchRoot: URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("ask-turns", isDirectory: true).path,
      environment: environment,
      settings: { settings ?? profileSettings(environment: environment) },
      readProviders: readers,
      mutations: ProviderAskMutationSurface(
        sessions: sessions ?? RielaSessionControlProvider(
          workingDirectory: workingDirectory, sessionStore: root, scope: scope
        ),
        bots: readers.bots,
        registry: readers.authoringRegistry.map { WorkflowRegistryGraphQLDocumentExecutor(localProvider: $0) },
        workingDirectory: workingDirectory, environment: environment
      ),
      rielaExecutablePath: rielaExecutablePath, scope: scope
    )
  }

  private static func profileSettings(environment: [String: String]) -> RielaAppAssistantSettings {
    let home = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
    let root = RielaAppProfileStore.defaultAppRootURL(homeDirectory: home)
    let profile = RielaAppProfileStore(appRootURL: root).loadActiveProfileName()
    return RielaAppDaemonWorkflowStore(profileName: profile, homeDirectory: home).loadReadOnlyResult()
      .state?.assistant ?? RielaAppAssistantSettings()
  }
}

/// Composes Ask for hosts that already expose the control plane.
public enum AskGraphQLHost {
  public static func executor(
    workingDirectory: String, sessionStore: String?, scope: WorkflowScope = .auto, environment: [String: String],
    settings: RielaAppAssistantSettings? = nil, console: (any GraphQLConsoleProviding)? = nil,
    sessions: (any GraphQLSessionControlProviding)? = nil,
    rielaExecutablePath: String? = Bundle.main.executableURL.flatMap { url in
      url.lastPathComponent == "riela" ? url.resolvingSymlinksInPath().path : nil
    },
    next: any GraphQLDocumentExecuting
  ) -> AskGraphQLDocumentExecutor {
    executor(
      workingDirectory: workingDirectory, sessionStore: sessionStore, scope: scope, environment: environment,
      settings: settings, console: console, sessions: sessions, pairing: nil,
      rielaExecutablePath: rielaExecutablePath, next: next
    )
  }

  static func executor(
    workingDirectory: String, sessionStore: String?, scope: WorkflowScope = .auto, environment: [String: String],
    settings: RielaAppAssistantSettings? = nil, console: (any GraphQLConsoleProviding)? = nil,
    sessions: (any GraphQLSessionControlProviding)? = nil, pairing: PairingService?,
    rielaExecutablePath: String? = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
    next: any GraphQLDocumentExecuting
  ) -> AskGraphQLDocumentExecutor {
    let host = AskHost.local(
      workingDirectory: workingDirectory, sessionStore: sessionStore, scope: scope, environment: environment,
      settings: settings, console: console, sessions: sessions, rielaExecutablePath: rielaExecutablePath
    )
    let identity = pairing?.identity
    let provider = AskGraphQLProvider(
      service: AskService(host: host), registry: RemoteRegistry(environment: environment),
      origin: { .local(serverId: identity?.serverId, serverName: identity?.name, at: Date()) }
    )
    return AskGraphQLDocumentExecutor(provider: provider, next: next)
  }
}
