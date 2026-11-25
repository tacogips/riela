import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum RielaPairingAddress {
  public static func validate(_ address: String) throws -> URL {
    guard !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          let components = URLComponents(string: address),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host?.lowercased(), !host.isEmpty,
          !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          !host.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          components.path.isEmpty || components.path == "/",
          let url = components.url else {
      throw RielaAPIKeyStore.StoreError.pairingAddressNotRoutable
    }

    let bareHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    let dnsHost = bareHost.hasSuffix(".") ? String(bareHost.dropLast()) : bareHost
    guard dnsHost != "localhost", dnsHost != "*", !dnsHost.isEmpty else {
      throw RielaAPIKeyStore.StoreError.pairingAddressNotRoutable
    }
    let isPrivate = try privateLiteral(bareHost, dnsHost: dnsHost)
    guard scheme == "https" || isPrivate else {
      throw RielaAPIKeyStore.StoreError.pairingAddressRequiresTLS
    }
    return url
  }

  private static func privateLiteral(_ host: String, dnsHost: String) throws -> Bool {
    var v4 = in_addr()
    let isIPv4Literal = host.withCString { inet_pton(AF_INET, $0, &v4) } == 1
    // Reject loopback and unspecified legacy numeric spellings as well.
    if isIPv4Literal || dnsHost.withCString({ inet_aton($0, &v4) }) == 1 {
      let number = UInt32(bigEndian: v4.s_addr)
      let first = number >> 24
      let second = (number >> 16) & 0xff
      guard first != 127, number != 0 else {
        throw RielaAPIKeyStore.StoreError.pairingAddressNotRoutable
      }
      return isIPv4Literal && (first == 10 || (first == 172 && (16...31).contains(second))
        || (first == 192 && second == 168) || (first == 100 && (64...127).contains(second)))
    }

    var v6 = in6_addr()
    let literal = String(host.prefix(while: { $0 != "%" }))
    guard literal.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return false }
    return try withUnsafeBytes(of: v6) { bytes in
      let isLocal = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] <= 1
      let isMapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
      let isMappedLocal = isMapped && (bytes[12] == 127 || bytes.suffix(4).allSatisfy { $0 == 0 })
      guard !isLocal, !isMappedLocal else {
        throw RielaAPIKeyStore.StoreError.pairingAddressNotRoutable
      }
      return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }
  }
}
