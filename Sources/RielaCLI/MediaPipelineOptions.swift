import Foundation
import RielaCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum MediaPipelineOptions {
  static func normalizedURL(_ raw: String) -> URL? {
    guard var components = URLComponents(string: raw), let scheme = components.scheme,
      ["http", "https"].contains(scheme.lowercased()), components.host != nil
    else { return nil }
    if let host = components.host?.lowercased(),
      ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"].contains(host) {
      let id = components.queryItems?.first(where: { $0.name == "v" })?.value
      components.queryItems = (components.queryItems ?? []).filter {
        !["t", "si", "feature", "pp", "start"].contains($0.name.lowercased())
      }
      let path = components.path.split(separator: "/")
      let pathID: String?
      if host.hasSuffix("youtu.be") {
        pathID = path.first.map(String.init)
      } else if path.count > 1, ["shorts", "live", "embed"].contains(String(path[0])) {
        pathID = String(path[1])
      } else {
        pathID = nil
      }
      if let videoID = id ?? pathID {
        components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
      } else {
        components.scheme = "https"
        components.host = "www.youtube.com"
      }
    }
    if components.queryItems?.isEmpty == true { components.query = nil }
    return components.url
  }

  static func host(_ host: String, matches suffix: String) -> Bool {
    let normalized = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return host.lowercased() == normalized || host.lowercased().hasSuffix("." + normalized)
  }

  static func isSafeURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let rawHost = components.host?.lowercased()
    else { return false }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard !host.contains("%"), host != "localhost", !host.hasSuffix(".localhost"),
      !host.hasSuffix(".") else {
      return false
    }
    if host.contains(":"), isPrivateIPv6(host) { return false }
    if let address = parsedIPv4(host), isPrivateIPv4(address) { return false }
    return true
  }

  static func number(
    _ values: JSONObject, _ key: String, default defaultValue: Double, range: ClosedRange<Double>
  ) throws -> Double {
    guard let value = values[key] else { return defaultValue }
    let number: Double
    switch value {
    case .integer(let int): number = Double(int)
    case .number(let double): number = double
    default: throw MediaPipelineError.invalidOption(key)
    }
    guard number.isFinite, range.contains(number) else {
      throw MediaPipelineError.invalidOption(key)
    }
    return number
  }

  private static func isPrivateIPv6(_ host: String) -> Bool {
    var address = in6_addr()
    guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
    let bytes = withUnsafeBytes(of: &address) { Array($0) }
    let unspecified = bytes.allSatisfy { $0 == 0 }
    let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    let uniqueLocal = bytes[0] & 0xfe == 0xfc
    let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
    let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
    let compatible = bytes[0..<12].allSatisfy { $0 == 0 }
    guard mapped || compatible else { return unspecified || loopback || uniqueLocal || linkLocal }
    return unspecified || loopback || isPrivateIPv4(Array(bytes[12..<16]))
  }

  private static func parsedIPv4(_ host: String) -> [UInt8]? {
    var address = in_addr()
    guard host.withCString({ inet_aton($0, &address) }) == 1 else { return nil }
    return withUnsafeBytes(of: address.s_addr) { Array($0) }
  }

  private static func isPrivateIPv4(_ parts: [UInt8]) -> Bool {
    guard parts.count == 4 else { return false }
    let first = Int(parts[0])
    let second = Int(parts[1])
    return parts.allSatisfy { $0 == 0 } || first == 0 || first == 127 || first == 10
      || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168)
      || (first == 169 && second == 254)
  }
}

enum MediaPipelineError: Error {
  case invalidOption(String)
  case stage(String, String)
}
