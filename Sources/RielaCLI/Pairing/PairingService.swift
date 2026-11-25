import Foundation
import RielaCore
import RielaGraphQL
import RielaServer

struct PairingService: Sendable {
  private static let codeLifetime: TimeInterval = 600
  let store: RielaAPIKeyStore
  let identity: RielaServerIdentity

  init(store: RielaAPIKeyStore, serverName: String? = nil) throws {
    self.store = store
    identity = try RielaServerIdentity.loadOrCreate(root: store.root, name: serverName)
  }

  var audit: RielaPairingAudit { RielaPairingAudit(root: store.root) }

  static func scope(_ value: String?) throws -> RielaAPIKeyStore.Scope {
    guard let value else { return .operate }
    guard let scope = RielaAPIKeyStore.Scope(rawValue: value) else {
      throw BotStoreError(code: "pairing_scope_invalid", message: "Pairing scope must be read, operate, or admin")
    }
    return scope
  }

  func mint(address: String, scope: RielaAPIKeyStore.Scope, now: Date = Date()) throws -> PairingCodePayload {
    let code = try store.mintPairingCode(
      address: address, scope: scope, serverId: identity.serverId, now: now, ttl: Self.codeLifetime
    )
    audit.append(action: "mint", grantId: nil, clientName: nil, scope: scope.rawValue, remoteAddress: address, now: now)
    return PairingCodePayload(
      code: code, expiresAt: now.addingTimeInterval(Self.codeLifetime), address: address, scope: scope.rawValue
    )
  }

  func grants() throws -> PairingGrantListPayload {
    PairingGrantListPayload(grants: try store.pairingGrants().map { record in
      PairingGrant(grantId: record.id, clientName: record.name, scope: record.effectiveScope.rawValue,
                   createdAt: record.createdAt, lastUsedAt: record.lastUsedAt, revokedAt: record.revokedAt)
    })
  }

  func revoke(grantId: String, now: Date = Date()) throws -> PairingGrantListPayload {
    guard let grant = try store.pairingGrants().first(where: { $0.id == grantId }) else {
      throw BotStoreError(code: "pairing_grant_not_found", message: "Unknown pairing grant")
    }
    try store.revoke(id: grant.id, now: now)
    audit.append(action: "revoke", grantId: grant.id, clientName: grant.name,
                 scope: grant.effectiveScope.rawValue, remoteAddress: nil, now: now)
    return try grants()
  }
}

extension PairingCodePayload {
  var terminalOutput: String {
    "pairing code (expires in 10 minutes): \(code)\npairing address: \(address)\n"
  }
}
