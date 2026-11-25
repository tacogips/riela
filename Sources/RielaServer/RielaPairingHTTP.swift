import Foundation

public enum RielaPairingHTTP {
  public static let redeemRoute = (method: "POST", path: "/api/v1/pairing/redeem")

  private struct RedeemRequest: Decodable {
    let secret: String
    let clientName: String
  }

  public static func response(
    for request: RielaHTTPRequest, store: RielaAPIKeyStore, identity: RielaServerIdentity,
    audit: RielaPairingAudit, now: Date
  ) -> RielaHTTPResponse? {
    guard request.method == redeemRoute.method, request.path == redeemRoute.path else { return nil }
    var response: RielaHTTPResponse
    if request.headers["origin"] == nil,
       request.headers["content-type"]?.split(separator: ";").first?
         .trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
       request.body.count <= 4_096,
       let input = try? JSONDecoder().decode(RedeemRequest.self, from: request.body),
       let issued = try? store.redeemPairingCode(secret: input.secret, clientName: input.clientName, now: now) {
      let grant = issued.record
      let scope = grant.effectiveScope.rawValue
      let auditName = grant.name.contains(input.secret) ? nil : grant.name
      audit.append(action: "redeem", grantId: grant.id, clientName: auditName, scope: scope, remoteAddress: nil, now: now)
      response = .json(status: 200, .object([
        "token": .string(issued.token), "grantId": .string(grant.id), "scope": .string(scope),
        "serverId": .string(identity.serverId), "serverName": .string(identity.name)
      ]))
    } else {
      audit.append(action: "redeem_failed", grantId: nil, clientName: nil, scope: nil, remoteAddress: nil, now: now)
      response = .json(status: 403, .object(["error": .string("pairing_code_invalid")]))
    }
    response.headers["Cache-Control"] = "no-store"
    return response
  }
}
