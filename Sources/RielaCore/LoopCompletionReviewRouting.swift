public func reconcileCompletionReviewRouting(
  when: [String: Bool],
  payload: JSONObject
) -> OutputContractRoutingReconciliation {
  guard isCompletionReviewPayload(payload) else {
    return OutputContractRoutingReconciliation(when: when)
  }

  let expected = expectedGoalCompletionRouting(from: payload)
  let expectedWhen: [String: Bool] = [
    "needs_replan": expected.needsReplan,
    "needs_work": expected.needsWork
  ]
  if when == expectedWhen {
    return OutputContractRoutingReconciliation(when: when)
  }

  let alwaysOverridesRouting = when["always"] == true && (expected.needsReplan || expected.needsWork)
  let contradictsPayload =
    when["needs_replan"] != expected.needsReplan || when["needs_work"] != expected.needsWork
  guard alwaysOverridesRouting || contradictsPayload else {
    return OutputContractRoutingReconciliation(when: when)
  }

  return OutputContractRoutingReconciliation(
    when: expectedWhen,
    diagnostics: [
      "loop completion-review routing reconciled from \(sortedRoutingDescription(when)) to \(sortedRoutingDescription(expectedWhen))"
    ]
  )
}

private func isCompletionReviewPayload(_ payload: JSONObject) -> Bool {
  if payload["goalAchieved"] != nil {
    return true
  }
  if case let .string(decision)? = payload["decision"] {
    return ["needs_work", "needs_replan", "accepted"].contains(decision)
  }
  return false
}

private func expectedGoalCompletionRouting(from payload: JSONObject) -> (needsReplan: Bool, needsWork: Bool) {
  let decision: String?
  if case let .string(value)? = payload["decision"] {
    decision = value
  } else {
    decision = nil
  }

  let goalAchieved: Bool?
  if case let .bool(value)? = payload["goalAchieved"] {
    goalAchieved = value
  } else {
    goalAchieved = nil
  }

  switch decision {
  case "needs_replan":
    return (true, false)
  case "needs_work":
    return (false, true)
  case "accepted":
    if goalAchieved == false {
      return (false, true)
    }
    return (false, false)
  default:
    if goalAchieved == false {
      return (false, true)
    }
    return (false, false)
  }
}

private func sortedRoutingDescription(_ when: [String: Bool]) -> String {
  when.keys.sorted().map { "\($0)=\(when[$0] == true)" }.joined(separator: ",")
}
