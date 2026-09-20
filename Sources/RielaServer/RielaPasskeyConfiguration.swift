import Crypto
import Foundation

public struct RielaPasskeyConfiguration: Sendable {
  public static let originEnvironmentKey = "RIELA_WEB_ORIGIN"
  public static let rootEnvironmentKey = "RIELA_WEB_AUTH_ROOT"
  public let origin: String
  public let authority: String
  public let relyingPartyID: String

  public init(origin: String) throws {
    guard let url = URLComponents(string: origin), let host = url.host,
          !host.isEmpty, url.user == nil, url.password == nil,
          url.path.isEmpty, url.query == nil, url.fragment == nil,
          let scheme = url.scheme,
          scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
          origin.hasPrefix("\(scheme)://"), origin == origin.lowercased() else {
      throw RielaPasskeyError.configuration
    }
    self.origin = origin
    authority = String(origin.dropFirst(scheme.count + 3))
    relyingPartyID = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
  }

  public static func storeRoot(home: URL, environment: [String: String]) -> URL {
    if let path = environment[rootEnvironmentKey], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return home.appendingPathComponent(".riela/web-auth", isDirectory: true)
  }
}

public enum RielaPasskeyError: Error, LocalizedError {
  case configuration, invalidRequest, expired, unauthorized, capacity, storeUnavailable, userNotFound

  public var errorDescription: String? {
    switch self {
    case .configuration: "Set RIELA_WEB_ORIGIN to an HTTPS origin without a path (HTTP is allowed only on localhost)."
    case .invalidRequest: "Invalid Passkey request. Start again."
    case .expired: "This registration or login has expired or was already used. Start again."
    case .unauthorized: "Passkey authentication was not accepted. Try again or ask the server administrator for a registration link."
    case .capacity: "Too many pending authentication requests. Try again shortly."
    case .storeUnavailable: "The Passkey store is unavailable. Check server storage and permissions."
    case .userNotFound: "The user or Passkey was not found."
    }
  }
}

enum PasskeyEncoding {
  static func randomToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return encode(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  static func decode(_ value: String) throws -> Data {
    guard !value.isEmpty, value.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }) else { throw RielaPasskeyError.invalidRequest }
    let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: padded), encode(data) == value else { throw RielaPasskeyError.invalidRequest }
    return data
  }

  static func digest(_ value: String) -> String { encode(Data(SHA256.hash(data: Data(value.utf8)))) }
}
