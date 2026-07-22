import Foundation

public struct LoopTerminalCorridor: Equatable, Sendable {
  public var entryStepId: String
  public var stepIds: [String]

  public init(entryStepId: String, stepIds: [String]) {
    self.entryStepId = entryStepId
    self.stepIds = stepIds
  }

  public func contains(_ stepId: String) -> Bool {
    stepIds.contains(stepId)
  }
}

public struct LoopTerminalCorridorSelector: Sendable {
  public init() {}

  public func select(
    workflow: WorkflowDefinition,
    originStepId: String,
    selectedOriginTransitions: [WorkflowStepTransition]? = nil
  ) -> LoopTerminalCorridor? {
    let stepsById = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
    guard stepsById[originStepId] != nil else {
      return nil
    }
    guard !hasReachableDispatchBoundary(
      originStepId: originStepId,
      selectedOriginTransitions: selectedOriginTransitions,
      stepsById: stepsById
    ) else {
      return nil
    }

    let reachableSinkIds = reachableTransitionlessSinks(
      originStepId: originStepId,
      selectedOriginTransitions: selectedOriginTransitions,
      stepsById: stepsById
    )
    let corridors = reachableSinkIds.compactMap { sinkId in
      corridor(endingAt: sinkId, stepsById: stepsById)
    }
    guard corridors.count == reachableSinkIds.count,
          let selected = corridors.first,
          corridors.allSatisfy({ $0 == selected }) else {
      return nil
    }
    return selected
  }

  func hasReachableDispatchBoundary(
    workflow: WorkflowDefinition,
    originStepId: String,
    selectedOriginTransitions: [WorkflowStepTransition]? = nil
  ) -> Bool {
    let stepsById = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
    return hasReachableDispatchBoundary(
      originStepId: originStepId,
      selectedOriginTransitions: selectedOriginTransitions,
      stepsById: stepsById
    )
  }

  private func reachableTransitionlessSinks(
    originStepId: String,
    selectedOriginTransitions: [WorkflowStepTransition]?,
    stepsById: [String: WorkflowStepRef]
  ) -> [String] {
    var pending = [originStepId]
    var visited: Set<String> = []
    var sinks: Set<String> = []

    while let stepId = pending.popLast() {
      guard visited.insert(stepId).inserted, let step = stepsById[stepId] else {
        continue
      }
      let authoredTransitions = step.transitions ?? []
      if authoredTransitions.isEmpty {
        sinks.insert(stepId)
        continue
      }
      let transitions = stepId == originStepId ? (selectedOriginTransitions ?? authoredTransitions) : authoredTransitions
      for transition in transitions where isLocalLinearEdge(transition) && stepsById[transition.toStepId] != nil {
        pending.append(transition.toStepId)
      }
    }
    return sinks.sorted()
  }

  private func hasReachableDispatchBoundary(
    originStepId: String,
    selectedOriginTransitions: [WorkflowStepTransition]?,
    stepsById: [String: WorkflowStepRef]
  ) -> Bool {
    var pending = [originStepId]
    var visited: Set<String> = []

    while let stepId = pending.popLast() {
      guard visited.insert(stepId).inserted, let step = stepsById[stepId] else {
        continue
      }
      let authoredTransitions = step.transitions ?? []
      let transitions = stepId == originStepId ? (selectedOriginTransitions ?? authoredTransitions) : authoredTransitions
      if transitions.contains(where: { !isLocalLinearEdge($0) }) {
        return true
      }
      for transition in transitions where stepsById[transition.toStepId] != nil {
        pending.append(transition.toStepId)
      }
    }
    return false
  }

  private func corridor(
    endingAt sinkStepId: String,
    stepsById: [String: WorkflowStepRef]
  ) -> LoopTerminalCorridor? {
    guard let sink = stepsById[sinkStepId], (sink.transitions ?? []).isEmpty else {
      return nil
    }
    var suffix = [sinkStepId]
    var currentStepId = sinkStepId

    while true {
      let incoming = incomingEdges(to: currentStepId, stepsById: stepsById)
      guard incoming.count == 1, let predecessor = stepsById[incoming[0].stepId] else {
        break
      }
      let transitions = predecessor.transitions ?? []
      guard predecessor.loop?.gateId == nil,
            predecessor.loop?.role != "gate",
            transitions.count == 1,
            isLocalLinearEdge(transitions[0]),
            isUnconditional(transitions[0]),
            transitions[0].toStepId == currentStepId else {
        break
      }
      suffix.insert(predecessor.id, at: 0)
      currentStepId = predecessor.id
    }

    return LoopTerminalCorridor(entryStepId: suffix[0], stepIds: suffix)
  }

  private func incomingEdges(
    to stepId: String,
    stepsById: [String: WorkflowStepRef]
  ) -> [(stepId: String, transition: WorkflowStepTransition)] {
    stepsById.values.flatMap { step in
      (step.transitions ?? []).compactMap { transition in
        guard isLocalLinearEdge(transition), transition.toStepId == stepId else {
          return nil
        }
        return (step.id, transition)
      }
    }
  }

  private func isLocalLinearEdge(_ transition: WorkflowStepTransition) -> Bool {
    transition.toWorkflowId == nil && transition.resumeStepId == nil && transition.fanout == nil
  }

  private func isUnconditional(_ transition: WorkflowStepTransition) -> Bool {
    guard let label = transition.label else {
      return true
    }
    return label == "always" || label == "true"
  }
}
