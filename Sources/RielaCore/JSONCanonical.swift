import Crypto
import Foundation

public enum JSONCanonical {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
      try container.encode(formatter.string(from: rounded))
    }
    let encoded = try encoder.encode(value)
    let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
    var output = ""
    try write(json, to: &output)
    return Data(output.utf8)
  }
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid canonical UTC date"))
      }
      return date
    }
    return decoder
  }
  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
  }()
  private static func write(_ value: JSONValue, to output: inout String) throws {
    switch value {
    case .null: output += "null"
    case let .bool(value): output += value ? "true" : "false"
    case let .integer(value): output += String(value)
    case let .number(value):
      guard value.isFinite else { throw CanonicalError.nonFiniteNumber }
      output += value.description
    case let .string(value): output += quote(value)
    case let .array(values):
      output += "["
      for index in values.indices { if index > 0 { output += "," }; try write(values[index], to: &output) }
      output += "]"
    case let .object(values):
      output += "{"
      let keys = values.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
      for index in keys.indices {
        if index > 0 { output += "," }
        let key = keys[index]; output += quote(key) + ":"
        if let entry = values[key] { try write(entry, to: &output) }
      }
      output += "}"
    }
  }
  private static func quote(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22: result += "\\\""
      case 0x5c: result += "\\\\"
      case 0x08: result += "\\b"
      case 0x09: result += "\\t"
      case 0x0a: result += "\\n"
      case 0x0c: result += "\\f"
      case 0x0d: result += "\\r"
      case 0..<0x20: result += String(format: "\\u%04x", scalar.value)
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }
  private enum CanonicalError: Error { case nonFiniteNumber }
}
