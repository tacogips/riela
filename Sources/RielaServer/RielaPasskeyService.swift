import Foundation
import WebAuthn

/// One process owns ceremonies, desktop grants and expiring sessions. A restart
/// requires login again; durable users, keys and invitations are shared with CLI.
public actor RielaPasskeyService {
  let configuration: RielaPasskeyConfiguration
  let store: RielaPasskeyStore
  let manager: WebAuthnManager
  let now: @Sendable () -> Date
  var ceremonies: [String: Ceremony] = [:]
  var devices: [String: Device] = [:]
  var sessions: [String: Session] = [:]
  var recentStarts: [Date] = []

  enum CeremonyKind { case registration(invitation: String, userID: String), authentication(deviceID: String?) }
  struct Ceremony { let challenge: [UInt8]; let kind: CeremonyKind; let expiresAt: Date }
  struct Session { let credentialID: String; let expiresAt: Date }
  struct Device {
    let secretHash: String
    let code: String
    let expiresAt: Date
    var credentialID: String?
  }

  public init(configuration: RielaPasskeyConfiguration, root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.configuration = configuration
    self.store = RielaPasskeyStore(root: root, origin: configuration.origin)
    self.manager = WebAuthnManager(configuration: .init(
      relyingPartyID: configuration.relyingPartyID, relyingPartyName: "Riela", relyingPartyOrigin: configuration.origin
    ))
    self.now = now
  }

  public func isAuthenticated(_ request: RielaHTTPRequest) -> Bool {
    prune()
    guard let token = bearer(request), let session = sessions[PasskeyEncoding.digest(token)] else { return false }
    return (try? store.credential(id: session.credentialID)) != nil
  }

  public func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    do {
      guard request.headers["host"] == configuration.authority else { return failure(.invalidRequest, status: 403) }
      if request.path == "/api/v1/auth/status", request.method == "GET" {
        return try json(["method": "passkey", "origin": configuration.origin])
      }
      guard request.method == "POST" else { return failure(.invalidRequest, status: 405) }
      guard request.headers["origin"] == configuration.origin else { return failure(.invalidRequest, status: 403) }
      guard request.headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json" else {
        return failure(.invalidRequest, status: 415)
      }
      guard request.body.count <= 64 * 1024 else { return failure(.invalidRequest, status: 413) }
      prune()
      switch request.path {
      case "/api/v1/auth/register/options": return try beginRegistration(request.body)
      case "/api/v1/auth/register/finish": return try await finishRegistration(request.body)
      case "/api/v1/auth/login/options": return try beginAuthentication(request.body)
      case "/api/v1/auth/login/finish": return try finishAuthentication(request.body)
      case "/api/v1/auth/device/start": return try startDevice()
      case "/api/v1/auth/device/info":
        let input = try JSONDecoder().decode(DeviceInput.self, from: request.body)
        let device = try pendingDevice(input.deviceID)
        return try json(["code": device.code, "origin": configuration.origin])
      case "/api/v1/auth/device/poll", "/api/v1/auth/device/cancel": return try deviceResponse(request)
      case "/api/v1/auth/logout":
        if let token = bearer(request) { sessions.removeValue(forKey: PasskeyEncoding.digest(token)) }
        return try json(["status": "signed-out"])
      default: return failure(.invalidRequest, status: 404)
      }
    } catch let error as RielaPasskeyError {
      let status: Int
      switch error {
      case .expired: status = 410
      case .unauthorized: status = 401
      case .capacity: status = 429
      case .storeUnavailable, .configuration: status = 503
      default: status = 400
      }
      return failure(error, status: status)
    } catch {
      // Do not expose credentials, WebAuthn internals or filesystem details.
      return failure(.unauthorized, status: 401)
    }
  }

  func prune() {
    let date = now()
    ceremonies = ceremonies.filter { $0.value.expiresAt > date }
    devices = devices.filter { $0.value.expiresAt > date }
    sessions = sessions.filter { $0.value.expiresAt > date }
    recentStarts.removeAll { $0 < date.addingTimeInterval(-60) }
  }

  func admitStart() throws {
    guard recentStarts.count < 60, ceremonies.count < 256, devices.count < 256 else { throw RielaPasskeyError.capacity }
    recentStarts.append(now())
  }

  func takeCeremony(_ id: String) throws -> Ceremony {
    guard let ceremony = ceremonies.removeValue(forKey: id), ceremony.expiresAt > now() else { throw RielaPasskeyError.expired }
    return ceremony
  }

  func sessionResponse(credentialID: String) throws -> RielaHTTPResponse {
    guard sessions.count < 1024 else { throw RielaPasskeyError.capacity }
    let (user, _) = try store.credential(id: credentialID)
    let token = PasskeyEncoding.randomToken()
    sessions[PasskeyEncoding.digest(token)] = Session(credentialID: credentialID, expiresAt: now().addingTimeInterval(8 * 3600))
    return try json(["token": token, "user": user.name])
  }

  func json<Value: Encodable>(_ value: Value) throws -> RielaHTTPResponse {
    RielaHTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
                      body: try JSONEncoder().encode(value))
  }

  private func bearer(_ request: RielaHTTPRequest) -> String? {
    guard let header = request.headers["authorization"], header.hasPrefix("Bearer "), header.count < 256 else { return nil }
    return String(header.dropFirst(7))
  }

  private func failure(_ error: RielaPasskeyError, status: Int) -> RielaHTTPResponse {
    var response = RielaHTTPResponse.json(status: status, .object(["error": .object([
      "code": .string("passkey_error"), "message": .string(error.localizedDescription)
    ])]))
    response.headers["Cache-Control"] = "no-store"
    return response
  }
}
