import Foundation

extension RielaPasskeyService {
  struct DeviceInput: Decodable { let deviceID: String; let deviceSecret: String? }

  func startDevice() throws -> RielaHTTPResponse {
    try admitStart()
    let id = PasskeyEncoding.randomToken()
    let secret = PasskeyEncoding.randomToken()
    let code = String(PasskeyEncoding.randomToken().prefix(8)).uppercased()
    devices[id] = Device(secretHash: PasskeyEncoding.digest(secret), code: code, expiresAt: now().addingTimeInterval(300))
    return try json([
      "deviceID": id, "deviceSecret": secret, "code": code,
      "verificationURL": "\(configuration.origin)/#/auth/device/\(id)"
    ])
  }

  func pendingDevice(_ id: String) throws -> Device {
    guard let device = devices[id], device.expiresAt > now(), device.credentialID == nil else { throw RielaPasskeyError.expired }
    return device
  }

  func deviceResponse(_ request: RielaHTTPRequest) throws -> RielaHTTPResponse {
    let input = try JSONDecoder().decode(DeviceInput.self, from: request.body)
    guard let device = devices[input.deviceID], let secret = input.deviceSecret,
          device.expiresAt > now(), PasskeyEncoding.digest(secret) == device.secretHash else { throw RielaPasskeyError.expired }
    if request.path.hasSuffix("/cancel") {
      devices.removeValue(forKey: input.deviceID)
      return try json(["status": "cancelled"])
    }
    guard let credentialID = device.credentialID else { return try json(["status": "pending"]) }
    devices.removeValue(forKey: input.deviceID)
    return try sessionResponse(credentialID: credentialID)
  }
}
