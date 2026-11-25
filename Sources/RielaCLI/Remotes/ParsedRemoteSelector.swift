import ArgumentParser
import RielaCore
import RielaGraphQL

struct ParsedRemoteSelector: ParsableArguments, Sendable {
  @Option var remote: String?
  @Flag var allRemotes = false

  func resolve(environment: [String: String]) throws -> String {
    guard remote == nil || !allRemotes else {
      throw CLIUsageError("remote_selector_invalid: --remote and --all-remotes are mutually exclusive")
    }
    if allRemotes { return "*" }
    if let remote {
      guard remote != "*" else { throw CLIUsageError("remote_selector_invalid: use --all-remotes for multiple hosts") }
      return remote
    }
    return try RemoteRegistry(environment: environment).list().active
  }

  func client(for service: BotsService, transport: @escaping RemoteHTTP.Transport) throws -> SelectedBotRemote? {
    let selector = try resolve(environment: service.environment)
    guard selector != "local" else { return nil }
    return SelectedBotRemote(
      selector: selector,
      provider: BotsGraphQLProvider(
        workingDirectory: service.workingDirectory, sessionStoreRoot: service.sessionStoreRoot,
        environment: service.environment, pairing: nil, remoteTransport: transport
      )
    )
  }
}

struct SelectedBotRemote: Sendable {
  let selector: String
  let provider: BotsGraphQLProvider

  func requireSingle() throws {
    guard selector != "*" else {
      throw CLIUsageError("remote_selector_invalid: select one remote for this command")
    }
  }
}

func remoteHostText(_ origin: BotOrigin) -> String {
  origin.remote == "local" ? "" : "  host \(origin.remote)"
}
