import Foundation
import RielaCore

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

  init(_ values: JSONObject, workingDirectory: URL) throws {
    let rawURL = values["url"]?.stringValue
    let rawPath = values["path"]?.stringValue
    guard (rawURL != nil) != (rawPath != nil) else { throw VideoTranscribeError.invalidOptions }
    if let rawURL {
      guard let normalized = Self.normalizedURL(rawURL) else { throw VideoTranscribeError.invalidOptions }
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
    guard case let .object(stt) = values["stt"] ?? .object([:]) else { throw VideoTranscribeError.invalidOptions }
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
  }

  static func normalizedURL(_ raw: String) -> URL? {
    guard var components = URLComponents(string: raw), let scheme = components.scheme,
      ["http", "https"].contains(scheme.lowercased()), components.host != nil else { return nil }
    if let host = components.host?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"].contains(host) {
      components.queryItems = components.queryItems?.filter { $0.name.lowercased() != "t" && $0.name.lowercased() != "start" }
    }
    return components.url
  }

  static func number(_ values: JSONObject, _ key: String, default defaultValue: Double, range: ClosedRange<Double>) throws -> Double {
    guard let value = values[key] else { return defaultValue }
    let number: Double
    switch value {
    case let .integer(int): number = Double(int)
    case let .number(double): number = double
    default: throw VideoTranscribeError.invalidOptions
    }
    guard number.isFinite, range.contains(number) else { throw VideoTranscribeError.invalidOptions }
    return number
  }

  private static func boolean(_ value: JSONValue?) -> Bool? { if case let .bool(boolean)? = value { return boolean }; return nil }
}

enum VideoTranscribeError: Error {
  case invalidOptions
  case unsupportedProvider(String)
  case stage(String, String)
}
