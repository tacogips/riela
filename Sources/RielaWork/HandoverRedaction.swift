import Foundation
import RielaCore

public struct HandoverRedactionRules: Sendable {
  public var secretKeyNames: Set<String>
  /// Maps a secret value to the environment variable name that supplied it.
  public var boundValues: [String: String]

  /// Bound values shorter than this many UTF-8 bytes are redacted only when a
  /// string leaf equals them exactly, never as substrings of free text: values
  /// such as "1", "ok", or "abc" would otherwise shred ordinary prose and
  /// identifiers. Four bytes is the shortest length at which a value stops
  /// colliding with common English words and short tokens while still catching
  /// every realistic credential (API keys, bearer tokens, passwords).
  public static let minimumSubstringRedactionLength = 4

  public init(secretKeyNames: Set<String> = [], boundValues: [String: String] = [:]) {
    self.secretKeyNames = secretKeyNames
    self.boundValues = boundValues.filter { !$0.key.isEmpty }
  }

  public static func apply(_ value: JSONValue, rules: HandoverRedactionRules) -> JSONValue {
    switch value {
    case let .object(object):
      return .object(object.mapValues { $0 }.map { key, child in
        (key, rules.secretKeyNames.contains(key) ? .string("<redacted:\(key)>") : apply(child, rules: rules))
      }.reduce(into: [:]) { $0[$1.0] = $1.1 })
    case let .array(values):
      return .array(values.map { apply($0, rules: rules) })
    case let .string(string):
      if let name = rules.boundValues[string] { return .string("<redacted:\(name)>") }
      return .string(rules.redactText(string))
    default:
      return value
    }
  }

  /// Replaces every occurrence of a bound secret value inside free text with
  /// its `<redacted:NAME>` placeholder. Longer values are replaced first so a
  /// secret that contains another secret is never left half-redacted; ties are
  /// broken by value for determinism. Values shorter than
  /// `minimumSubstringRedactionLength` are skipped (see that constant).
  public func redactText(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    let candidates = boundValues
      .filter { $0.key.utf8.count >= Self.minimumSubstringRedactionLength }
      .sorted { lhs, rhs in
        let (left, right) = (lhs.key.utf8.count, rhs.key.utf8.count)
        return left != right ? left > right : lhs.key < rhs.key
      }
    var output = text
    for (value, name) in candidates where output.contains(value) {
      output = output.replacingOccurrences(of: value, with: "<redacted:\(name)>")
    }
    return output
  }

  public static func redactText(_ text: String, rules: HandoverRedactionRules) -> String {
    rules.redactText(text)
  }

  static func apply(_ object: JSONObject, rules: HandoverRedactionRules) -> JSONObject {
    guard case let .object(redacted) = apply(.object(object), rules: rules) else { return object }
    return redacted
  }
}
