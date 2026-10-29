import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct VideoTranscribeOptions: Sendable {
  enum Source: Sendable { case url(URL), path(URL) }
  let source: Source
  let outputDirectory: URL?
  let frameInterval: Double
  let frameDedupeThreshold: Double
  let frameWidth: Int
  let batchSeconds: Double
  let language: String?
  let sttPrompt: String?
  let model: String
  let concurrency: Int
  let maxAttempts: Int
  let maxDurationSeconds: Double
  let keepMedia: Bool
  let ytDlpPath: String?
  let ffmpegPath: String?
  let ffprobePath: String?
  let carryForwardFrame: Bool
  let cache: Bool
  let allowedHosts: [String]?
  let maxFileSizeMB: Int

  init(_ values: JSONObject, workingDirectory: URL) throws {
    let rawURL = values["url"]?.stringValue
    let rawPath = values["path"]?.stringValue
    guard (rawURL != nil) != (rawPath != nil) else { throw VideoTranscribeError.invalidOption("url/path") }
    if let rawURL {
      guard let normalized = Self.normalizedURL(rawURL) else { throw VideoTranscribeError.invalidOption("url") }
      source = .url(normalized)
    } else if let rawPath {
      let pathURL = (rawPath.hasPrefix("/") ? URL(fileURLWithPath: rawPath) : workingDirectory.appendingPathComponent(rawPath)).standardizedFileURL
      source = .path(pathURL)
    } else { throw VideoTranscribeError.invalidOptions }
    outputDirectory = values["outputDir"]?.stringValue.map {
      ($0.hasPrefix("/") ? URL(fileURLWithPath: $0) : workingDirectory.appendingPathComponent($0)).standardizedFileURL
    }
    frameInterval = try Self.number(values, "frameIntervalSeconds", default: 10, range: 1...600)
    frameDedupeThreshold = try Self.number(values, "frameDedupeThreshold", default: 0.15, range: 0...1)
    frameWidth = Int(try Self.number(values, "frameWidth", default: 960, range: 2...7680))
    batchSeconds = try Self.number(values, "batchSeconds", default: 180, range: 30...600)
    language = values["language"]?.stringValue
    sttPrompt = values["sttPrompt"]?.stringValue
    guard case let .object(stt) = values["stt"] ?? .object([:]) else { throw VideoTranscribeError.invalidOption("stt") }
    guard stt["provider"]?.stringValue == nil || stt["provider"]?.stringValue == "openai" else {
      throw VideoTranscribeError.unsupportedProvider(stt["provider"]?.stringValue ?? "")
    }
    model = stt["model"]?.stringValue ?? "gpt-4o-transcribe"
    concurrency = Int(try Self.number(stt, "concurrency", default: 4, range: 1...8))
    maxAttempts = Int(try Self.number(stt, "maxAttempts", default: 3, range: 1...8))
    maxDurationSeconds = try Self.number(values, "maxDurationSeconds", default: 7200, range: 1...172800)
    keepMedia = Self.boolean(values["keepMedia"]) ?? false
    ytDlpPath = values["ytDlpPath"]?.stringValue
    ffmpegPath = values["ffmpegPath"]?.stringValue
    ffprobePath = values["ffprobePath"]?.stringValue
    carryForwardFrame = Self.boolean(values["carryForwardFrame"]) ?? true
    cache = Self.boolean(values["cache"]) ?? true
    if let value = values["allowedHosts"] {
      guard case let .array(hostValues) = value, hostValues.allSatisfy({ $0.stringValue != nil }) else {
        throw VideoTranscribeError.invalidOption("allowedHosts")
      }
      allowedHosts = hostValues.compactMap(\.stringValue)
    } else { allowedHosts = nil }
    maxFileSizeMB = Int(try Self.number(values, "maxFileSizeMB", default: 2048, range: 1...1_000_000))
    if case let .url(url) = source {
      guard Self.isSafeURL(url), allowedHosts?.contains(where: { Self.host(url.host ?? "", matches: $0) }) ?? true else {
        throw VideoTranscribeError.invalidOption("url")
      }
    }
  }

  static func normalizedURL(_ raw: String) -> URL? {
    guard var components = URLComponents(string: raw), let scheme = components.scheme,
      ["http", "https"].contains(scheme.lowercased()), components.host != nil else { return nil }
    if let host = components.host?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"].contains(host) {
      let id = components.queryItems?.first(where: { $0.name == "v" })?.value
      components.queryItems = (components.queryItems ?? []).filter { !["t", "si", "feature", "pp", "start"].contains($0.name.lowercased()) }
      let pathComponents = components.path.split(separator: "/")
      let pathID: String?
      if host.hasSuffix("youtu.be") {
        pathID = pathComponents.first.map(String.init)
      } else if pathComponents.count > 1, ["shorts", "live", "embed"].contains(String(pathComponents[0])) {
        pathID = String(pathComponents[1])
      } else { pathID = nil }
      let videoID = id ?? pathID
      if let videoID {
        components = URLComponents(); components.scheme = "https"; components.host = "www.youtube.com"
        components.path = "/watch"; components.queryItems = [URLQueryItem(name: "v", value: videoID)]
      } else {
        components.scheme = "https"
        components.host = "www.youtube.com"
      }
    }
    if components.queryItems?.isEmpty == true { components.query = nil }
    return components.url
  }

  private static func host(_ host: String, matches suffix: String) -> Bool {
    let normalized = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return host.lowercased() == normalized || host.lowercased().hasSuffix("." + normalized)
  }

  private static func isSafeURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""), let rawHost = components.host?.lowercased() else { return false }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".") else { return false }
    if host.contains(":"), isPrivateIPv6(host) { return false }
    if let address = parsedIPv4(host), isPrivateIPv4(address) { return false }
    return true
  }

  private static func isPrivateIPv6(_ host: String) -> Bool {
    var address = in6_addr()
    guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
    let bytes = withUnsafeBytes(of: &address) { Array($0) }
    let isUnspecified = bytes.allSatisfy { $0 == 0 }
    let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    let isUniqueLocal = bytes[0] & 0xfe == 0xfc
    let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
    let isIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
    let isCompatibleIPv4 = bytes[0..<12].allSatisfy { $0 == 0 }
    guard isIPv4Mapped || isCompatibleIPv4 else { return isUnspecified || isLoopback || isUniqueLocal || isLinkLocal }
    return isUnspecified || isLoopback || isPrivateIPv4(Array(bytes[12..<16]))
  }

  private static func parsedIPv4(_ host: String) -> [UInt8]? {
    var address = in_addr()
    guard host.withCString({ inet_aton($0, &address) }) == 1 else { return nil }
    return withUnsafeBytes(of: address.s_addr) { Array($0) }
  }

  private static func isPrivateIPv4(_ parts: [UInt8]) -> Bool {
    guard parts.count == 4 else { return false }
    let first = Int(parts[0]), second = Int(parts[1])
    return parts.allSatisfy { $0 == 0 } || first == 0 || first == 127 || first == 10 ||
      (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168) ||
      (first == 169 && second == 254)
  }

  static func number(_ values: JSONObject, _ key: String, default defaultValue: Double, range: ClosedRange<Double>) throws -> Double {
    guard let value = values[key] else { return defaultValue }
    let number: Double
    switch value {
    case let .integer(int): number = Double(int)
    case let .number(double): number = double
    default: throw VideoTranscribeError.invalidOption(key)
    }
    guard number.isFinite, range.contains(number) else { throw VideoTranscribeError.invalidOption(key) }
    return number
  }

  private static func boolean(_ value: JSONValue?) -> Bool? { if case let .bool(boolean)? = value { return boolean }; return nil }
}

enum VideoTranscribeError: Error {
  case invalidOptions
  case invalidOption(String)
  case unsupportedProvider(String)
  case stage(String, String)
}
