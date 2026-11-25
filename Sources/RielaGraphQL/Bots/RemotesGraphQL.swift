import Foundation
import RielaCore

public struct RemoteSummary: Codable, Equatable, Sendable {
  public enum Connection: String, Codable, Sendable {
    case connected, disconnected
  }

  public let name: String
  public let address: String
  public let serverName: String
  public let scope: String
  public let lastSeenAt: Date?
  public let connection: Connection

  public init(
    name: String, address: String, serverName: String, scope: String,
    lastSeenAt: Date?, connection: Connection
  ) {
    self.name = name
    self.address = address
    self.serverName = serverName
    self.scope = scope
    self.lastSeenAt = lastSeenAt
    self.connection = connection
  }
}

public struct RemoteListPayload: Codable, Equatable, Sendable {
  public let active: String
  public let remotes: [RemoteSummary]

  public init(active: String, remotes: [RemoteSummary]) {
    self.active = active
    self.remotes = remotes
  }
}

public struct AddRemoteInput: Codable, Sendable {
  public let name: String
  public let code: String
  public let clientName: String?

  public init(name: String, code: String, clientName: String? = nil) {
    self.name = name
    self.code = code
    self.clientName = clientName
  }
}

public struct RemoveRemoteInput: Codable, Sendable {
  public let name: String

  public init(name: String) { self.name = name }
}

public struct UseRemoteInput: Codable, Sendable {
  public let name: String

  public init(name: String) { self.name = name }
}

extension BotsGraphQLProviding {
  public func remotes() async throws -> RemoteListPayload { throw Self.remoteRegistryUnavailable }
  public func addRemote(input: AddRemoteInput) async throws -> RemoteListPayload { throw Self.remoteRegistryUnavailable }
  public func removeRemote(input: RemoveRemoteInput) async throws -> RemoteListPayload { throw Self.remoteRegistryUnavailable }
  public func useRemote(input: UseRemoteInput) async throws -> RemoteListPayload { throw Self.remoteRegistryUnavailable }

  public func botMemoryHistory(botId: String, limit: Int, remote: String?) async throws -> BotMemoryHistoryPayload {
    throw Self.botHistoryUnavailable
  }

  public func botMemoryDiff(botId: String, changeId: String, remote: String?) async throws -> BotMemoryDiffPayload {
    throw Self.botHistoryUnavailable
  }

  public func botJobHistory(botId: String, job: BotJobKind?, limit: Int, remote: String?) async throws -> BotJobHistoryPayload {
    throw Self.botHistoryUnavailable
  }

  private static var botHistoryUnavailable: BotStoreError {
    BotStoreError(code: "bot_history_unavailable", message: "This provider does not expose bot history")
  }

  private static var remoteRegistryUnavailable: BotStoreError {
    BotStoreError(code: "remote_registry_unavailable", message: "This host has no remote registry")
  }
}

extension GraphQLSchemaGenerator {
  static let remoteRootFields: [String: FieldDescriptor] = [
    "Query.remotes": .init(name: "remotes", type: "RemoteListPayload!"),
    "Mutation.addRemote": .init(name: "addRemote", arguments: "input: AddRemoteInput!", type: "RemoteListPayload!"),
    "Mutation.removeRemote": .init(name: "removeRemote", arguments: "input: RemoveRemoteInput!", type: "RemoteListPayload!"),
    "Mutation.useRemote": .init(name: "useRemote", arguments: "input: UseRemoteInput!", type: "RemoteListPayload!")
  ]

  static let remoteTypes: [TypeDescriptor] = [
    .init(kind: .object, name: "RemoteSummary", fields: [
      .init(name: "name", type: "String!"),
      .init(name: "address", type: "String!"),
      .init(name: "serverName", type: "String!"),
      .init(name: "scope", type: "String!"),
      .init(name: "lastSeenAt", type: "String"),
      .init(name: "connection", type: "String!")
    ]),
    .init(kind: .object, name: "RemoteListPayload", fields: [
      .init(name: "active", type: "String!"),
      .init(name: "remotes", type: "[RemoteSummary!]!")
    ]),
    .init(kind: .input, name: "AddRemoteInput", fields: [
      .init(name: "name", type: "String!"),
      .init(name: "code", type: "String!"),
      .init(name: "clientName", type: "String")
    ]),
    .init(kind: .input, name: "RemoveRemoteInput", fields: [.init(name: "name", type: "String!")]),
    .init(kind: .input, name: "UseRemoteInput", fields: [.init(name: "name", type: "String!")])
  ]
}
