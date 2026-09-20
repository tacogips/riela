import Foundation
import SwiftCBOR
import WebAuthn

extension RielaPasskeyService {
  struct RegistrationInput: Decodable { let invitation: String }
  struct LoginInput: Decodable { let deviceID: String? }
  struct FinishInput<Value: Decodable>: Decodable { let ceremonyID: String; let credential: Value }
  struct CreationOptions: Encodable {
    let ceremonyID: String
    let publicKey: PublicKeyCredentialCreationOptions
    let excludeCredentials: [String]
  }
  struct AssertionOptions: Encodable { let ceremonyID: String; let publicKey: PublicKeyCredentialRequestOptions }

  func beginRegistration(_ data: Data) throws -> RielaHTTPResponse {
    try admitStart()
    let input = try JSONDecoder().decode(RegistrationInput.self, from: data)
    let user = try store.invitation(input.invitation, now: now())
    let options = manager.beginRegistration(user: .init(id: Array(try PasskeyEncoding.decode(user.id)), name: user.name, displayName: user.name))
    let id = PasskeyEncoding.randomToken()
    ceremonies[id] = Ceremony(challenge: options.challenge,
      kind: .registration(invitation: input.invitation, userID: user.id), expiresAt: now().addingTimeInterval(300))
    return try json(CreationOptions(ceremonyID: id, publicKey: options, excludeCredentials: user.credentials.map(\.id)))
  }

  func finishRegistration(_ data: Data) async throws -> RielaHTTPResponse {
    let input = try JSONDecoder().decode(FinishInput<RegistrationCredential>.self, from: data)
    let ceremony = try takeCeremony(input.ceremonyID)
    guard case let .registration(invitation, userID) = ceremony.kind else { throw RielaPasskeyError.invalidRequest }
    try validateClientData(input.credential.attestationResponse.clientDataJSON)
    let id = PasskeyEncoding.encode(Data(input.credential.rawID))
    guard input.credential.id.asString() == id else { throw RielaPasskeyError.invalidRequest }
    let attestation = try CBOR.decode(input.credential.attestationResponse.attestationObject, options: CBOROptions(maximumDepth: 16))
    guard case let .byteString(authData)? = attestation?["authData"], authData.count >= 55 else { throw RielaPasskeyError.invalidRequest }
    let idLength = Int(authData[53]) * 256 + Int(authData[54])
    guard idLength > 0, authData.count >= 55 + idLength,
          Array(authData[55..<(55 + idLength)]) == input.credential.rawID else { throw RielaPasskeyError.invalidRequest }
    try validateBackupFlags(authData, expected: nil)
    let credential = try await manager.finishRegistration(
      challenge: ceremony.challenge, credentialCreationData: input.credential, requireUserVerification: true,
      confirmCredentialIDNotRegisteredYet: { _ in true }
    )
    // The final duplicate/invitation checks and insert are one cross-process transaction.
    try store.transaction { state in
      let hash = PasskeyEncoding.digest(invitation)
      guard let invite = state.invitations[hash], invite.expiresAt > now(), invite.userID == userID,
            let index = state.users.firstIndex(where: { $0.id == userID && $0.enabled }),
            !state.users.contains(where: { $0.credentials.contains(where: { $0.id == id }) }) else {
        throw RielaPasskeyError.expired
      }
      guard state.users[index].credentials.count < 32 else { throw RielaPasskeyError.capacity }
      state.users[index].credentials.append(.init(id: id, publicKey: Data(credential.publicKey),
        signCount: credential.signCount, backupEligible: credential.backupEligible, revoked: false))
      state.invitations.removeValue(forKey: hash)
    }
    return try sessionResponse(credentialID: id)
  }

  func beginAuthentication(_ data: Data) throws -> RielaHTTPResponse {
    try admitStart()
    let input = try JSONDecoder().decode(LoginInput.self, from: data)
    if let device = input.deviceID { _ = try pendingDevice(device) }
    let options = manager.beginAuthentication(userVerification: .required)
    let id = PasskeyEncoding.randomToken()
    ceremonies[id] = Ceremony(challenge: options.challenge, kind: .authentication(deviceID: input.deviceID),
      expiresAt: now().addingTimeInterval(300))
    return try json(AssertionOptions(ceremonyID: id, publicKey: options))
  }

  func finishAuthentication(_ data: Data) throws -> RielaHTTPResponse {
    let input = try JSONDecoder().decode(FinishInput<AuthenticationCredential>.self, from: data)
    let ceremony = try takeCeremony(input.ceremonyID)
    guard case let .authentication(deviceID) = ceremony.kind else { throw RielaPasskeyError.invalidRequest }
    let id = PasskeyEncoding.encode(Data(input.credential.rawID))
    guard input.credential.id.asString() == id else { throw RielaPasskeyError.unauthorized }
    try validateClientData(input.credential.response.clientDataJSON)
    try store.transaction { state in
      guard let userIndex = state.users.firstIndex(where: { $0.enabled && $0.credentials.contains(where: { $0.id == id && !$0.revoked }) }),
            let keyIndex = state.users[userIndex].credentials.firstIndex(where: { $0.id == id }) else { throw RielaPasskeyError.unauthorized }
      let key = state.users[userIndex].credentials[keyIndex]
      guard let handle = input.credential.response.userHandle,
            PasskeyEncoding.encode(Data(handle)) == state.users[userIndex].id else { throw RielaPasskeyError.unauthorized }
      try validateBackupFlags(input.credential.response.authenticatorData, expected: key.backupEligible)
      let verified = try manager.finishAuthentication(credential: input.credential, expectedChallenge: ceremony.challenge,
        credentialPublicKey: Array(key.publicKey), credentialCurrentSignCount: key.signCount, requireUserVerification: true)
      state.users[userIndex].credentials[keyIndex].signCount = verified.newSignCount
    }
    if let deviceID {
      var device = try pendingDevice(deviceID)
      device.credentialID = id
      devices[deviceID] = device
      return try json(["status": "authorized"])
    }
    return try sessionResponse(credentialID: id)
  }

  private func validateClientData(_ bytes: [UInt8]) throws {
    struct ClientData: Decodable { let crossOrigin: Bool?; let topOrigin: String? }
    let data = try JSONDecoder().decode(ClientData.self, from: Data(bytes))
    guard data.crossOrigin != true, data.topOrigin == nil else { throw RielaPasskeyError.unauthorized }
  }

  private func validateBackupFlags(_ authData: [UInt8], expected: Bool?) throws {
    guard authData.count >= 37 else { throw RielaPasskeyError.invalidRequest }
    let eligible = authData[32] & 0x08 != 0
    let backedUp = authData[32] & 0x10 != 0
    guard !backedUp || eligible, expected == nil || eligible == expected else { throw RielaPasskeyError.unauthorized }
  }
}
