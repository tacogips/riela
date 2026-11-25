import ArgumentParser
import Foundation
import RielaCore
import RielaGraphQL

enum RemoteClientAction: String, CaseIterable {
  case add, list, show, remove, use
}

struct ParsedRemoteOptions: ParsableArguments {
  @Option var name: String?
  @Option var code: String?
  @Option var clientName: String?
  @Option var output: String?
}

struct RemoteRegistryOperations: Sendable {
  let registry: RemoteRegistry
  let transport: RemoteHTTP.Transport

  func list() throws -> RemoteListPayload {
    let state = try registry.list()
    return RemoteListPayload(active: state.active, remotes: state.remotes.map { summary($0) })
  }

  func add(_ input: AddRemoteInput) async throws -> RemoteListPayload {
    try registry.requireAvailable(name: input.name)
    let decoded = try RemotePairingClient.decode(code: input.code)
    let result = try await RemotePairingClient(transport: transport).redeem(
      code: input.code, clientName: input.clientName ?? ProcessInfo.processInfo.hostName
    )
    let now = Date()
    try registry.add(record: RemoteRecord(
      name: input.name, address: decoded.address.absoluteString, serverId: result.serverId,
      serverName: result.serverName, grantId: result.grantId, scope: result.scope, addedAt: now, lastSeenAt: now
    ), token: result.token)
    return try list()
  }

  func show(_ name: String) async throws -> RemoteListPayload {
    let (record, token) = try registry.credentials(name: name)
    let provider = RemoteBotsProvider(record: record, token: token, registry: registry, transport: transport)
    let connection: RemoteSummary.Connection
    do {
      _ = try await provider.bots(filter: nil)
      connection = .connected
    } catch let error as BotStoreError where error.code == "remote_unreachable" || error.code == "remote_unauthorized" {
      connection = .disconnected
    }
    let state = try registry.list()
    return RemoteListPayload(active: state.active, remotes: [summary(try registry.record(name: name), connection: connection)])
  }

  private func summary(_ record: RemoteRecord, connection: RemoteSummary.Connection? = nil) -> RemoteSummary {
    RemoteSummary(
      name: record.name, address: record.address, serverName: record.serverName, scope: record.scope.rawValue,
      lastSeenAt: record.lastSeenAt, connection: connection ?? (record.lastSeenAt == nil ? .disconnected : .connected)
    )
  }
}

extension BotsGraphQLProvider {
  public func remotes() async throws -> RemoteListPayload {
    try remoteOperations.list()
  }

  public func addRemote(input: AddRemoteInput) async throws -> RemoteListPayload {
    try await remoteOperations.add(input)
  }

  public func removeRemote(input: RemoveRemoteInput) async throws -> RemoteListPayload {
    try registry.remove(name: input.name)
    return try remoteOperations.list()
  }

  public func useRemote(input: UseRemoteInput) async throws -> RemoteListPayload {
    try registry.use(name: input.name)
    return try remoteOperations.list()
  }

  private var remoteOperations: RemoteRegistryOperations {
    RemoteRegistryOperations(registry: registry, transport: remoteTransport)
  }
}

extension ScopedParityCommandRunner {
  func remoteResult(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let action = RemoteClientAction(rawValue: options.command ?? "list"),
          options.output == .json || options.output == .text else {
      throw CLIUsageError("remote requires add, list, show, remove or use, with json or text output")
    }
    guard let parsed = try? ParsedRemoteOptions.parse(options.arguments) else {
      throw CLIUsageError("Invalid remote options. See riela remote --help.")
    }
    let registry = RemoteRegistry(environment: CLIRuntimeEnvironment.mergedProcessEnvironment())
    let operations = RemoteRegistryOperations(registry: registry, transport: remoteTransport)
    if action == .add {
      guard options.target == nil, let name = parsed.name, let code = parsed.code else {
        throw CLIUsageError("remote add requires --name and --code")
      }
      return try renderRemote(await operations.add(AddRemoteInput(name: name, code: code, clientName: parsed.clientName)), options)
    }
    guard parsed.name == nil, parsed.code == nil, parsed.clientName == nil else {
      throw CLIUsageError("--name, --code and --client-name are only accepted by remote add")
    }
    if action == .list {
      guard options.target == nil else { throw CLIUsageError("remote list does not accept a name") }
      return try renderRemote(operations.list(), options)
    }
    guard let name = options.target else { throw CLIUsageError("remote \(action.rawValue) requires a name") }
    switch action {
    case .show:
      return try renderRemote(await operations.show(name), options)
    case .remove:
      try registry.remove(name: name)
      var result = try renderRemote(operations.list(), options)
      result.stderr = "grant not revoked on the server; revoke it there with riela serve pairing revoke\n"
      return result
    case .use:
      try registry.use(name: name)
      return try renderRemote(operations.list(), options)
    case .add, .list:
      throw CLIUsageError("Invalid remote command")
    }
  }

  private func renderRemote(_ payload: RemoteListPayload, _ options: CLICommandOptions) throws -> CLICommandResult {
    try renderBot(payload, options: options, text: (
      (payload.active == "local" ? ["* local"] : []) + payload.remotes.map {
        let active = payload.active == $0.name ? "* " : "  "
        let lastSeen = $0.lastSeenAt.map(RoutineStore.timestamp) ?? "-"
        return "\(active)\($0.name)  \($0.address)  \($0.serverName)  \($0.scope)  \($0.connection.rawValue)  \(lastSeen)"
      }
    ).joined(separator: "\n") + "\n")
  }
}
