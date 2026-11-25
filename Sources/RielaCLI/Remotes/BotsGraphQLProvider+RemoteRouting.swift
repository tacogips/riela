import Foundation
import RielaCore
import RielaGraphQL

extension BotsGraphQLProvider {
  func forwarded(_ selector: String?) throws -> RemoteBotsProvider? {
    guard case let .remote(record, token) = try RemoteRouting.resolve(remote: selector, registry: registry) else {
      return nil
    }
    return forward(record: record, token: token)
  }

  func forward(record: RemoteRecord, token: String) -> RemoteBotsProvider {
    RemoteBotsProvider(record: record, token: token, registry: registry, transport: remoteTransport, now: service.now)
  }

  func eachRemote<Value>(
    _ operation: (RemoteBotsProvider) async throws -> Value
  ) async throws -> [Value] {
    var values: [Value] = []
    for record in try registry.list().remotes.sorted(by: { $0.name < $1.name }) {
      do {
        let credentials = try registry.credentials(name: record.name)
        values.append(try await operation(forward(record: credentials.record, token: credentials.token)))
      } catch let error as BotStoreError where error.code == "remote_not_found" || error.code == "remote_unreachable" {
        continue
      }
    }
    return values
  }

  func remoteOverview(_ remote: RemoteBotsProvider, filter: BotFilter?) async throws -> BotListPayload {
    do {
      return try await remote.bots(filter: filter)
    } catch let error as BotStoreError where error.code == "remote_unreachable" {
      return Self.disconnectedOverview(remote.record)
    }
  }

  private static func disconnectedOverview(_ record: RemoteRecord) -> BotListPayload {
    let observedAt = record.lastKnown?.observedAt ?? record.lastSeenAt ?? record.addedAt
    let origin = BotOrigin(
      remote: record.name, serverId: record.serverId, serverName: record.serverName,
      verified: record.lastKnown != nil, connection: "disconnected", observedAt: observedAt
    )
    let timestamp = RoutineStore.timestamp(observedAt)
    let cached = record.lastKnown?.bots ?? []
    let rows = cached.isEmpty ? [
      RemoteLastKnown.Bot(
        botId: record.name, name: record.name,
        counts: BotOverviewCounts(needsYou: 0, working: 0, waiting: 0, planned: 0)
      )
    ] : cached
    let bots = rows.map { row in
      BotOverviewRow(
        bot: BotRecord(botId: row.botId, name: row.name, createdAt: timestamp, updatedAt: timestamp), counts: row.counts,
        inProgress: [], lastActivityAt: nil, lastResult: nil, listState: BotListState(), section: .disconnected,
        workspaceGroup: record.name, origin: origin
      )
    }
    return BotListPayload(bots: bots, groups: [], origin: origin)
  }
}
