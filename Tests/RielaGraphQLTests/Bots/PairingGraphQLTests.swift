import Foundation
import RielaCore
import RielaGraphQL
import XCTest

final class PairingGraphQLTests: XCTestCase {
  func testPairingRootsDecodeInputsAndProjectAllDocumentedFields() async {
    let provider = RecordingBotsProvider()
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let list = "{ result: pairingGrants { grants { grantId clientName scope createdAt lastUsedAt revokedAt } } }"
    let mint = """
      mutation { result: mintPairingCode(input: {address: "https://riela.example", scope: "read"}) {
        code expiresAt address scope
      } }
      """
    let revoke = """
      mutation { result: revokePairingGrant(input: {grantId: "grant"}) { grants { grantId revokedAt } } }
      """
    let at = "1970-01-01T00:00:00Z"
    let outputs: [(String, JSONValue)] = [
      (list, .object(["grants": .array([.object([
        "grantId": .string("grant"), "clientName": .string("client"), "scope": .string("operate"),
        "createdAt": .string(at), "lastUsedAt": .string(at), "revokedAt": .null
      ])])])),
      (mint, .object(["code": .string("fixture-code"), "expiresAt": .string(at),
                      "address": .string("https://riela.example"), "scope": .string("read")])),
      (revoke, .object(["grants": .array([.object(["grantId": .string("grant"), "revokedAt": .string(at)])])]))
    ]
    for (query, payload) in outputs {
      let response = await executor.execute(GraphQLDocumentRequest(query: query, isLocallyTrusted: true))
      XCTAssertEqual(response.body["data"], .object(["result": payload]))
    }
    let calls = await provider.calls
    XCTAssertEqual(calls, ["pairingGrants", "mint:https://riela.example:read", "revoke:grant"])
  }
}

extension RecordingBotsProvider {
  func pairingGrants() async throws -> PairingGrantListPayload {
    recordCatalogCall("pairingGrants")
    return PairingGrantListPayload(grants: [pairingGrant(revoked: false)])
  }

  func mintPairingCode(input: MintPairingCodeInput) async throws -> PairingCodePayload {
    recordCatalogCall("mint:\(input.address):\(input.scope ?? "")")
    return PairingCodePayload(
      code: "fixture-code", expiresAt: Date(timeIntervalSince1970: 0),
      address: input.address, scope: input.scope ?? "operate"
    )
  }

  func revokePairingGrant(input: RevokePairingGrantInput) async throws -> PairingGrantListPayload {
    recordCatalogCall("revoke:\(input.grantId)")
    return PairingGrantListPayload(grants: [pairingGrant(revoked: true)])
  }

  private func pairingGrant(revoked: Bool) -> PairingGrant {
    let at = Date(timeIntervalSince1970: 0)
    return PairingGrant(grantId: "grant", clientName: "client", scope: "operate", createdAt: at,
                        lastUsedAt: at, revokedAt: revoked ? at : nil)
  }
}
