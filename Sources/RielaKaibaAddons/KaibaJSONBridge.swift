import KaibaClient
import RielaCore

/// Structural JSON conversion at the Riela/KaibaClient boundary. This target
/// deliberately has no dependency on Kaiba's application or storage models.
func kaibaJSONValue(_ value: RielaCore.JSONValue) -> KaibaJSONValue {
  switch value {
  case .null: .null
  case let .bool(value): .bool(value)
  case let .integer(value): .integer(Int(value))
  case let .number(value): .double(value)
  case let .string(value): .string(value)
  case let .array(values): .array(values.map(kaibaJSONValue))
  case let .object(values): .object(values.mapValues(kaibaJSONValue))
  }
}

func rielaJSONValue(_ value: KaibaJSONValue) -> RielaCore.JSONValue {
  switch value {
  case .null: .null
  case let .bool(value): .bool(value)
  case let .integer(value): .integer(Int64(value))
  case let .double(value): .number(value)
  case let .string(value): .string(value)
  case let .array(values): .array(values.map(rielaJSONValue))
  case let .object(values): .object(values.mapValues(rielaJSONValue))
  }
}
