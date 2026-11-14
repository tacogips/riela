import RielaAddonSupport
import RielaCore

func noteAddonInvalidInput(_ message: String) -> AdapterExecutionError {
  AdapterExecutionError(.invalidInput, message)
}

func noteString(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
  nonEmptyString(config[key].map { renderJSONTemplates($0, variables: variables) })
    ?? nonEmptyString(variables[key])
}

func noteIntValue(_ value: JSONValue?, variables: JSONObject) -> Int? {
  let rendered = value.map { renderJSONTemplates($0, variables: variables) }
  switch rendered {
  case let .integer(integer): return Int(integer)
  case let .number(number): return Int(exactly: number)
  case let .string(string): return Int(string)
  default: return nil
  }
}

func boolValue(_ value: JSONValue?) -> Bool? {
  switch value {
  case let .bool(value): return value
  case let .string(value): return Bool(value)
  default: return nil
  }
}

func intValue(_ value: JSONValue?) -> Int? {
  switch value {
  case let .integer(value): return Int(value)
  case let .number(value): return Int(exactly: value)
  case let .string(value): return Int(value)
  default: return nil
  }
}
