import Foundation

public enum VersionedHistoryDiff {
  private enum ParseError: Error { case invalid }

  private indirect enum JSONNode {
    case object([String: JSONNode])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
  }

  public static func diff(before: Data, after: Data) -> [VersionedHistoryDiffEntry] {
    guard let left = parse(before), let right = parse(after) else {
      let prefix = zip(before, after).prefix { $0 == $1 }.count
      let suffix = zip(before.reversed(), after.reversed()).prefix { $0 == $1 }.count
      return [VersionedHistoryDiffEntry(path: "", op: "replace", beforeJSON: nil, afterJSON: nil, encoding: "bytes",
        beforeSHA256: VersionedHistoryCodec.sha256(before), afterSHA256: VersionedHistoryCodec.sha256(after),
        beforeByteCount: Int64(before.count), afterByteCount: Int64(after.count), prefixByteCount: Int64(prefix), suffixByteCount: Int64(min(suffix, min(before.count, after.count) - prefix)))]
    }
    var result: [VersionedHistoryDiffEntry] = []
    compare(left, right, path: "", into: &result)
    return result
  }

  private static func parse(_ data: Data) -> JSONNode? {
    var parser = Parser(data: data)
    return try? parser.parse()
  }

  private static func compare(_ before: JSONNode, _ after: JSONNode, path: String, into result: inout [VersionedHistoryDiffEntry]) {
    switch (before, after) {
    case let (.object(left), .object(right)):
      for key in Set(left.keys).union(right.keys).sorted(by: utf8Less) {
        let child = path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        switch (left[key], right[key]) {
        case let (.some(a), .some(b)): compare(a, b, path: child, into: &result)
        case let (.some(a), nil): result.append(entry(path: child, op: "remove", before: a, after: nil))
        case let (nil, .some(b)): result.append(entry(path: child, op: "add", before: nil, after: b))
        default: break
        }
      }
    case let (.array(left), .array(right)):
      let sharedCount = min(left.count, right.count)
      for index in 0..<sharedCount { compare(left[index], right[index], path: path + "/\(index)", into: &result) }
      if left.count > sharedCount {
        for index in sharedCount..<left.count { result.append(entry(path: path + "/\(index)", op: "remove", before: left[index], after: nil)) }
      } else if right.count > sharedCount {
        for index in sharedCount..<right.count { result.append(entry(path: path + "/\(index)", op: "add", before: nil, after: right[index])) }
      }
    default:
      if canonical(before) != canonical(after) { result.append(entry(path: path, op: "replace", before: before, after: after)) }
    }
  }

  private static func entry(path: String, op: String, before: JSONNode?, after: JSONNode?) -> VersionedHistoryDiffEntry {
    VersionedHistoryDiffEntry(path: path, op: op, beforeJSON: before.map(canonical), afterJSON: after.map(canonical), encoding: nil,
      beforeSHA256: nil, afterSHA256: nil, beforeByteCount: nil, afterByteCount: nil, prefixByteCount: nil, suffixByteCount: nil)
  }

  private static func canonical(_ node: JSONNode) -> Data {
    let text: String
    switch node {
    case let .object(values):
      let members = values.keys.sorted(by: utf8Less).compactMap { key -> String? in
        guard let value = values[key] else { return nil }
        return quote(key) + ":" + (String(bytes: canonical(value), encoding: .utf8) ?? "null")
      }
      text = "{" + members.joined(separator: ",") + "}"
    case let .array(values):
      text = "[" + values.map { String(bytes: canonical($0), encoding: .utf8) ?? "null" }.joined(separator: ",") + "]"
    case let .string(value): text = quote(value)
    case let .number(value): text = value
    case let .bool(value): text = value ? "true" : "false"
    case .null: text = "null"
    }
    return Data(text.utf8)
  }

  private static func quote(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
    return String(bytes: data, encoding: .utf8) ?? "\"\""
  }
  private static func utf8Less(_ left: String, _ right: String) -> Bool { left.utf8.lexicographicallyPrecedes(right.utf8) }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0
    init(data: Data) { bytes = Array(data) }
    mutating func parse() throws -> JSONNode {
      skipSpace(); let node = try value(); skipSpace()
      guard index == bytes.count else { throw ParseError.invalid }
      return node
    }
    mutating func value() throws -> JSONNode {
      skipSpace(); guard index < bytes.count else { throw ParseError.invalid }
      switch bytes[index] {
      case 123: return try object()
      case 91: return try array()
      case 34: return .string(try string())
      case 116: try literal("true"); return .bool(true)
      case 102: try literal("false"); return .bool(false)
      case 110: try literal("null"); return .null
      default: return try number()
      }
    }
    mutating func object() throws -> JSONNode {
      index += 1; skipSpace(); var result: [String: JSONNode] = [:]
      if take(125) { return .object(result) }
      while true {
        guard index < bytes.count, bytes[index] == 34 else { throw ParseError.invalid }
        let key = try string(); skipSpace(); guard take(58) else { throw ParseError.invalid }
        result[key] = try value(); skipSpace()
        if take(125) { return .object(result) }
        guard take(44) else { throw ParseError.invalid }; skipSpace()
      }
    }
    mutating func array() throws -> JSONNode {
      index += 1; skipSpace(); var result: [JSONNode] = []
      if take(93) { return .array(result) }
      while true { result.append(try value()); skipSpace(); if take(93) { return .array(result) }; guard take(44) else { throw ParseError.invalid } }
    }
    mutating func string() throws -> String {
      let start = index; index += 1
      while index < bytes.count {
        if bytes[index] == 92 { index += 2; continue }
        if bytes[index] == 34 { index += 1; let raw = Data(bytes[start..<index]); return try JSONDecoder().decode(String.self, from: raw) }
        index += 1
      }
      throw ParseError.invalid
    }
    mutating func number() throws -> JSONNode {
      let start = index
      while index < bytes.count, [45, 43, 46, 69, 101, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57].contains(bytes[index]) { index += 1 }
      let pattern = "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$"
      guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8),
            text.range(of: pattern, options: .regularExpression) != nil else { throw ParseError.invalid }
      return .number(text)
    }
    mutating func literal(_ text: String) throws {
      for byte in text.utf8 {
        guard index < bytes.count, bytes[index] == byte else { throw ParseError.invalid }
        index += 1
      }
    }
    mutating func skipSpace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
  }
}
