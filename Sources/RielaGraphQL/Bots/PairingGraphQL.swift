import Foundation

public struct MintPairingCodeInput: Codable, Sendable {
  public let address: String
  public let scope: String?
}

public struct RevokePairingGrantInput: Codable, Sendable {
  public let grantId: String
}

public struct PairingCodePayload: Codable, Sendable {
  public let code: String
  public let expiresAt: Date
  public let address: String
  public let scope: String

  public init(code: String, expiresAt: Date, address: String, scope: String) {
    self.code = code
    self.expiresAt = expiresAt
    self.address = address
    self.scope = scope
  }
}

public struct PairingGrant: Codable, Sendable {
  public let grantId: String
  public let clientName: String
  public let scope: String
  public let createdAt: Date
  public let lastUsedAt: Date?
  public let revokedAt: Date?

  public init(
    grantId: String, clientName: String, scope: String, createdAt: Date, lastUsedAt: Date?, revokedAt: Date?
  ) {
    self.grantId = grantId
    self.clientName = clientName
    self.scope = scope
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.revokedAt = revokedAt
  }

  private enum CodingKeys: String, CodingKey {
    case grantId, clientName, scope, createdAt, lastUsedAt, revokedAt
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(grantId, forKey: .grantId)
    try container.encode(clientName, forKey: .clientName)
    try container.encode(scope, forKey: .scope)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(lastUsedAt, forKey: .lastUsedAt)
    try container.encode(revokedAt, forKey: .revokedAt)
  }
}

public struct PairingGrantListPayload: Codable, Sendable {
  public let grants: [PairingGrant]

  public init(grants: [PairingGrant]) {
    self.grants = grants
  }
}

extension GraphQLSchemaGenerator {
  static let pairingRootFields: [String: FieldDescriptor] = [
    "Query.pairingGrants": .init(name: "pairingGrants", type: "PairingGrantListPayload!"),
    "Mutation.mintPairingCode": .init(
      name: "mintPairingCode", arguments: "input: MintPairingCodeInput!", type: "PairingCodePayload!"
    ),
    "Mutation.revokePairingGrant": .init(
      name: "revokePairingGrant", arguments: "input: RevokePairingGrantInput!", type: "PairingGrantListPayload!"
    )
  ]

  static let pairingTypes: [TypeDescriptor] = [
    .init(kind: .object, name: "PairingGrant", fields: [
      .init(name: "grantId", type: "String!"),
      .init(name: "clientName", type: "String!"),
      .init(name: "scope", type: "String!"),
      .init(name: "createdAt", type: "String!"),
      .init(name: "lastUsedAt", type: "String"),
      .init(name: "revokedAt", type: "String")
    ]),
    .init(kind: .object, name: "PairingGrantListPayload", fields: [
      .init(name: "grants", type: "[PairingGrant!]!")
    ]),
    .init(kind: .object, name: "PairingCodePayload", fields: [
      .init(name: "code", type: "String!"),
      .init(name: "expiresAt", type: "String!"),
      .init(name: "address", type: "String!"),
      .init(name: "scope", type: "String!")
    ]),
    .init(kind: .input, name: "MintPairingCodeInput", fields: [
      .init(name: "address", type: "String!"),
      .init(name: "scope", type: "String")
    ]),
    .init(kind: .input, name: "RevokePairingGrantInput", fields: [
      .init(name: "grantId", type: "String!")
    ])
  ]
}
