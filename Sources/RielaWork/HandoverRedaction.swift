import Foundation
import RielaCore

public struct HandoverRedactionRules: Sendable {
  public var secretKeyNames: Set<String>
  /// Maps a secret value to the environment variable name that supplied it.
  public var boundValues: [String: String]

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
      guard let name = rules.boundValues[string] else { return value }
      return .string("<redacted:\(name)>")
    default:
      return value
    }
  }

  static func apply(_ object: JSONObject, rules: HandoverRedactionRules) -> JSONObject {
    guard case let .object(redacted) = apply(.object(object), rules: rules) else { return object }
    return redacted
  }
}
