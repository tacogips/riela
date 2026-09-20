import Crypto
import Foundation
import SwiftCBOR
import XCTest
@testable import RielaServer

/// Produces real ES256 WebAuthn data. Invalid assertions are signed with the
/// same key so tests distinguish policy validation from broken signatures.
struct PasskeyTestAuthenticator {
  let key = P256.Signing.PrivateKey()
  let id = Data((0..<32).map { UInt8($0) })
  let origin = "https://riela.example"

  func registration(options: [String: Any], flags: UInt8 = 0x45, wrongID: Bool = false) throws -> [String: Any] {
    let publicKey = try XCTUnwrap(options["publicKey"] as? [String: Any])
    let challenge = try XCTUnwrap(publicKey["challenge"] as? String)
    let client = try JSONSerialization.data(withJSONObject: ["type": "webauthn.create", "challenge": challenge, "origin": origin])
    let rawKey = Array(key.publicKey.x963Representation)
    let cose: CBOR = .map([
      .unsignedInt(1): .unsignedInt(2), .unsignedInt(3): .negativeInt(6), .negativeInt(0): .unsignedInt(1),
      .negativeInt(1): .byteString(Array(rawKey[1..<33])), .negativeInt(2): .byteString(Array(rawKey[33..<65]))
    ])
    var authData = Array(SHA256.hash(data: Data("riela.example".utf8))) + [flags, 0, 0, 0, 0]
    authData += Array(repeating: 0, count: 16) + [0, 32] + Array(id) + cose.encode()
    let attestation: CBOR = .map([
      .utf8String("fmt"): .utf8String("none"), .utf8String("attStmt"): .map([:]), .utf8String("authData"): .byteString(authData)
    ])
    let rawID = wrongID ? Data(repeating: 42, count: 32) : id
    return ["id": PasskeyEncoding.encode(rawID), "rawId": PasskeyEncoding.encode(rawID), "type": "public-key",
      "response": ["clientDataJSON": PasskeyEncoding.encode(client), "attestationObject": PasskeyEncoding.encode(Data(attestation.encode()))]]
  }

  func assertion(
    options: [String: Any], userID: String, origin: String? = nil, rpID: String = "riela.example",
    challenge: String? = nil, flags: UInt8 = 5, count: UInt8 = 1, crossOrigin: Bool = false, corruptSignature: Bool = false
  ) throws -> [String: Any] {
    let publicKey = try XCTUnwrap(options["publicKey"] as? [String: Any])
    let client = try JSONSerialization.data(withJSONObject: [
      "type": "webauthn.get", "challenge": challenge ?? XCTUnwrap(publicKey["challenge"] as? String),
      "origin": origin ?? self.origin, "crossOrigin": crossOrigin
    ])
    let authData = Data(Array(SHA256.hash(data: Data(rpID.utf8))) + [flags, 0, 0, 0, count])
    var signature = try key.signature(for: authData + Data(SHA256.hash(data: client))).derRepresentation
    if corruptSignature { signature[signature.count - 1] ^= 1 }
    return ["id": PasskeyEncoding.encode(id), "rawId": PasskeyEncoding.encode(id), "type": "public-key", "response": [
      "clientDataJSON": PasskeyEncoding.encode(client), "authenticatorData": PasskeyEncoding.encode(authData),
      "signature": PasskeyEncoding.encode(signature), "userHandle": userID
    ]]
  }
}
