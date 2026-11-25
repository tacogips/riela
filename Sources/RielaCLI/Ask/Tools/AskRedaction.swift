import RielaAdapters
import RielaCore
import RielaWork

enum AskRedaction {
  static func apply(
    _ value: JSONValue, environment: [String: String], additionalValues: [String: String] = [:]
  ) -> JSONValue {
    apply(value, rules: rules(environment: environment, additionalValues: additionalValues))
  }

  static func text(
    _ value: String, environment: [String: String], additionalValues: [String: String] = [:]
  ) -> String {
    text(value, rules: rules(environment: environment, additionalValues: additionalValues))
  }

  private static func rules(environment: [String: String], additionalValues: [String: String]) -> HandoverRedactionRules {
    var rules = BotMemoryRuntime.redactionRules(environment: environment)
    rules.boundValues.merge(additionalValues.filter { !$0.key.isEmpty }) { _, hostName in hostName }
    return rules
  }

  private static func apply(_ value: JSONValue, rules: HandoverRedactionRules) -> JSONValue {
    switch value {
    case let .object(values): return .object(values.mapValues { apply($0, rules: rules) })
    case let .array(values): return .array(values.map { apply($0, rules: rules) })
    case let .string(value): return .string(text(value, rules: rules))
    default: return value
    }
  }

  private static func text(_ value: String, rules: HandoverRedactionRules) -> String {
    let redacted = rules.boundValues[value].map { "<redacted:\($0)>" } ?? rules.redactText(value)
    return redactAdapterSensitiveText(redacted)
  }
}
