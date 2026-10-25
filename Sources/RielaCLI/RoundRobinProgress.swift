import Foundation
import RielaCore

/// Pure bounded turn selection. A reservation is an attempt, never an ACK.
enum RoundRobinProgress {
  static func next(_ config: JSONObject, maximum: Int) throws -> JSONObject {
    guard case let .array(items)? = config["items"], items.count <= 16,
      case let .bool(budget) = config["budgetAvailable"] ?? .bool(true) else { throw invalid() }
    var ids: [String] = [], eligible: [Bool] = []
    for value in items {
      guard case let .object(item) = value, Set(item.keys) == ["id", "eligible"],
        case let .string(id)? = item["id"], !id.isEmpty, id.utf8.count <= 256,
        !id.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
        case let .bool(allowed)? = item["eligible"] else { throw invalid() }
      ids.append(id); eligible.append(allowed)
    }
    guard Set(ids.map { Data($0.utf8) }).count == ids.count else { throw invalid() }
    var count = 0, cursor = 0
    if let raw = config["state"], raw != .null {
      guard case let .object(state) = raw,
        Set(state.keys) == ["version", "mode", "maximumTurns", "ids", "count", "cursor"],
        state["version"] == .integer(1), state["mode"] == .string("round-robin"),
        state["maximumTurns"] == .integer(Int64(maximum)),
        case let .array(old)? = state["ids"], old.count == ids.count,
        case let .integer(turns)? = state["count"], (0...Int64(maximum)).contains(turns),
        case let .integer(position)? = state["cursor"], position >= 0,
        position < Int64(max(1, ids.count)) else { throw invalid() }
      for (value, id) in zip(old, ids) {
        guard case let .string(text) = value, Data(text.utf8) == Data(id.utf8) else { throw invalid() }
      }
      count = Int(turns); cursor = Int(position)
      guard count >= ids.count || cursor == count, !ids.isEmpty || count == 0 else { throw invalid() }
    }
    var selected: Int?, reason: String
    let first = count < ids.count
    if !budget { reason = "budget"
    } else if count >= maximum { reason = "limit"
    } else if ids.isEmpty { reason = "empty"
    } else if first { selected = count; reason = "selected"
    } else if let index = (0..<ids.count).map({ (cursor + $0) % ids.count }).first(where: { eligible[$0] }) {
      selected = index; reason = "selected"
    } else { reason = "no-eligible" }
    if let selected { count += 1; cursor = (selected + 1) % ids.count }
    return ["state": .object(["version": .integer(1), "mode": .string("round-robin"),
      "maximumTurns": .integer(Int64(maximum)), "ids": .array(ids.map(JSONValue.string)),
      "count": .integer(Int64(count)), "cursor": .integer(Int64(cursor))]),
      "count": .integer(Int64(count)), "item": selected.map { .string(ids[$0]) } ?? .null,
      "firstTurn": .bool(selected != nil && first), "reason": .string(reason)]
  }

  private static func invalid() -> AdapterExecutionError { .init(.invalidInput, "invalid bounded round-robin progress metadata") }
}
