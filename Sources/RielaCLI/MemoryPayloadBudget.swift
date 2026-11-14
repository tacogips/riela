import RielaAddonSupport
import RielaCore
import RielaMemory

/// A per-record JSONB storage budget, explicitly bounded at the workflow boundary.
func memoryPayloadBudget(config: JSONObject, variables: JSONObject) throws -> Int {
  guard let value = config["maxPayloadBytes"] ?? variables["maxPayloadBytes"] else {
    return MemorySearchOptions.defaultMaxPayloadBytes
  }
  let rendered = try renderAddonConfig(value, variables: variables)
  let number: Int?
  switch rendered {
  case let .integer(value): number = Int(exactly: value)
  case let .number(value): number = value.isFinite ? Int(exactly: value) : nil
  default: number = nil
  }
  guard let number, (1...67_108_864).contains(number) else {
    throw AdapterExecutionError(.invalidInput, "maxPayloadBytes must be an integer in 1...67108864")
  }
  return number
}
