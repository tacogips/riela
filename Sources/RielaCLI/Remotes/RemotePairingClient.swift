import Foundation
import RielaCore
import RielaServer

struct RemotePairingClient: Sendable {
  struct Redemption: Decodable, Sendable {
    let token: String
    let grantId: String
    let scope: RielaAPIKeyStore.Scope
    let serverId: String
    let serverName: String
  }

  struct DecodedCode: Sendable {
    let address: URL
    let secret: String
    let serverId: String
  }

  private struct Code: Decodable {
    let address: String
    let secret: String
    let serverId: String
  }

  private struct Request: Encodable {
    let secret: String
    let clientName: String
  }

  let transport: RemoteHTTP.Transport

  init(transport: @escaping RemoteHTTP.Transport = RemoteHTTP.production) {
    self.transport = transport
  }

  static func decode(code: String) throws -> DecodedCode {
    let prefix = "rp1."
    let payload = code.dropFirst(prefix.count)
    guard code.hasPrefix(prefix), !payload.isEmpty, payload.utf8.count <= 4_096,
          payload.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
    else { throw invalidCode }
    let base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let padding = String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
    guard let data = Data(base64Encoded: base64 + padding),
          let decoded = try? JSONDecoder().decode(Code.self, from: data),
          !decoded.secret.isEmpty, !decoded.serverId.isEmpty,
          let address = try? RielaPairingAddress.validate(decoded.address) else { throw invalidCode }
    return DecodedCode(address: address, secret: decoded.secret, serverId: decoded.serverId)
  }

  func redeem(code: String, clientName: String) async throws -> Redemption {
    let decoded = try Self.decode(code: code)
    var request = try RemoteHTTP.post(endpoint: decoded.address, path: RielaPairingHTTP.redeemRoute.path)
    request.httpBody = try JSONEncoder().encode(Request(secret: decoded.secret, clientName: clientName))
    let (data, status) = try await RemoteHTTP.send(request, via: transport)
    if status == 403 { throw Self.invalidCode }
    guard status == 200, let result = try? JSONDecoder().decode(Redemption.self, from: data),
          RemoteRegistry.validToken(result.token), !result.grantId.isEmpty else { throw RemoteHTTP.invalidResponse }
    guard result.serverId == decoded.serverId else {
      throw BotStoreError(code: "pairing_server_mismatch", message: "The pairing response has a different server identity")
    }
    let publicMetadata = [result.grantId, result.serverName, result.serverId]
    guard publicMetadata.allSatisfy({ !$0.contains(result.token) && !$0.contains(decoded.secret) && !$0.contains(code) }) else {
      throw RemoteHTTP.invalidResponse
    }
    return result
  }

  private static var invalidCode: BotStoreError {
    BotStoreError(code: "pairing_code_invalid", message: "The pairing code is invalid or expired")
  }
}
