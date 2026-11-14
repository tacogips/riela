import Foundation
import RielaCore
import RielaGraphQL
import RielaViewer

/// The shared console read seam (design delta D8). `riela serve` and the
/// desktop host both build this provider from their own daemon state, so the
/// two consoles read one projection through GraphQL. It replaces the
/// `/api/v1/instances` and `/api/v1/ops/overview` routes, which are deleted.
@MainActor
public struct RielaConsoleGraphQLProvider {
  private let profileName: RielaAppProfileName
  private let state: RielaAppDaemonWorkflowState
  private let instances: [WorkflowInstance]
  private let workflowSources: [RielaAppDaemonWorkflowCandidate]
  private let revision: Int
  private let sessionStoreRootPath: String
  private let runtimeSnapshot: (String) -> RielaAppDaemonWorkflowRuntime.RuntimeSnapshot
  private let environment: (WorkflowInstance) -> [String: String]

  public init(
    profile: RielaAppProfileName,
    state: RielaAppDaemonWorkflowState,
    instances: [WorkflowInstance],
    sources: [RielaAppDaemonWorkflowCandidate],
    revision: Int,
    sessionStoreRoot: String,
    runtimeSnapshot: @escaping (String) -> RielaAppDaemonWorkflowRuntime.RuntimeSnapshot,
    environment: @escaping (WorkflowInstance) -> [String: String]
  ) {
    profileName = profile
    self.state = state
    self.instances = instances
    workflowSources = sources
    self.revision = revision
    sessionStoreRootPath = sessionStoreRoot
    self.runtimeSnapshot = runtimeSnapshot
    self.environment = environment
  }

  public func consoleInstanceList() -> GraphQLConsoleInstanceListPayload {
    let availableIdentities = Set(instances.map(\.identity))
    let available = instances.map(consoleInstance(_:))
    let missing = state.preferences
      .filter { !availableIdentities.contains($0.key) }
      .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
      .map { identity, preference in
        missingSourceInstance(identity: identity, preference: preference)
      }
    return GraphQLConsoleInstanceListPayload(
      profile: profileName.rawValue,
      revision: revision,
      items: available + missing
    )
  }

  public func consoleInstanceDetail(identity: String) -> GraphQLConsoleInstancePayload {
    if let instance = instances.first(where: { $0.identity == identity }) {
      return GraphQLConsoleInstancePayload(
        profile: profileName.rawValue,
        revision: revision,
        item: consoleInstance(instance)
      )
    }
    if let preference = state.preferences[identity] {
      return GraphQLConsoleInstancePayload(
        profile: profileName.rawValue,
        revision: revision,
        item: missingSourceInstance(identity: identity, preference: preference)
      )
    }
    return GraphQLConsoleInstancePayload(profile: profileName.rawValue, revision: revision, item: nil)
  }

  /// One payload for the command-deck dashboard: every discovered workflow
  /// graph, instance runtime status, and recent runs.
  public func opsOverviewPayload() -> GraphQLOpsOverviewPayload {
    let projection = WorkflowWebProjectionPolicy()
    let formatter = ISO8601DateFormatter()
    var diagnostics: [String] = []
    let sources = Array(workflowSources.prefix(60))
    var workflows: [GraphQLOpsOverviewWorkflowDTO] = []
    for source in sources {
      let workflowURL = URL(fileURLWithPath: source.workflowDirectory, isDirectory: true)
        .appendingPathComponent("workflow.json")
      guard let data = try? Data(contentsOf: workflowURL),
            data.count <= WorkflowWebProjectionPolicy.definitionResponseLimit,
            let workflow = validateAuthoredWorkflowData(data).workflow else {
        diagnostics.append(projection.persistedSummary(
          "Workflow definition unavailable for source \(projection.safeIdentifier(source.id))",
          context: .diagnostic
        ).value)
        continue
      }
      let steps = Array(workflow.steps.prefix(120))
      let nodes = Array(workflow.nodes.prefix(120))
      var transitionBudget = 240
      workflows.append(GraphQLOpsOverviewWorkflowDTO(
        sourceId: projection.identifier(source.id).value,
        name: projection.displayText(source.displayName).value,
        workflowId: projection.identifier(workflow.workflowId).value,
        scope: source.sourceScope.rawValue,
        sourceKind: source.packageDirectory == nil ? "directory" : "package",
        description: projection.displayText(workflow.description).value,
        entryStepId: projection.identifier(workflow.entryStepId).value,
        managerStepId: workflow.managerStepId.map { projection.identifier($0).value },
        steps: steps.map { step in
          let availableTransitions = min(step.transitions?.count ?? 0, transitionBudget)
          let transitions = Array((step.transitions ?? []).prefix(availableTransitions))
          transitionBudget -= transitions.count
          return GraphQLOpsOverviewStepDTO(
            id: projection.identifier(step.id).value,
            nodeId: projection.identifier(step.nodeId).value,
            role: step.role.map(\.rawValue),
            description: step.description.map { projection.displayText($0).value },
            transitions: transitions.map { transition in
              GraphQLOpsOverviewTransitionDTO(
                toStepId: projection.identifier(transition.toStepId).value,
                label: transition.label.map { projection.displayText($0).value },
                fanoutJoinStepId: transition.fanout.map { projection.identifier($0.joinStepId).value }
              )
            }
          )
        },
        nodes: nodes.map { node in
          GraphQLOpsOverviewNodeDTO(
            id: projection.identifier(node.id).value,
            kind: node.kind.map(\.rawValue),
            role: node.role.map(\.rawValue),
            addon: node.addon.map { projection.identifier($0.name).value }
          )
        },
        stepsTruncated: workflow.steps.count > steps.count || workflow.nodes.count > nodes.count
      ))
    }
    let overviewInstances = instances.map { instance in
      GraphQLOpsOverviewInstanceDTO(
        id: instance.identity,
        sourceId: instance.sourceIdentity,
        isDefault: instance.isDefault,
        name: projection.displayText(instance.displayName).value,
        workflowId: projection.identifier(instance.source.workflowId).value,
        status: runtimeSnapshot(instance.identity).status.rawValue,
        active: instance.preference.active
      )
    }
    var runRecords: [(updatedAt: Date, run: GraphQLOpsOverviewRunDTO)] = []
    for instance in instances {
      guard let viewerState = try? WorkflowViewerLoader().loadBounded(
        WorkflowViewerLoadRequest(
          workflowDirectory: instance.source.workflowDirectory,
          sessionStoreRoot: sessionStoreRootPath
        ),
        maximumSessionCount: 21
      ) else {
        diagnostics.append(projection.persistedSummary(
          "Runs unavailable for instance \(projection.safeIdentifier(instance.identity))",
          context: .diagnostic
        ).value)
        continue
      }
      for session in viewerState.sessions.prefix(20) {
        runRecords.append((session.updatedAt, GraphQLOpsOverviewRunDTO(
          instanceId: projection.identifier(instance.identity).value,
          sessionId: projection.identifier(session.sessionId).value,
          workflowId: projection.identifier(session.workflowId).value,
          status: session.status.rawValue,
          currentStepId: session.currentStepId.map { projection.identifier($0).value },
          activeStepIds: session.activeStepIds.prefix(20).map { projection.identifier($0).value },
          updatedAt: formatter.string(from: session.updatedAt)
        )))
      }
    }
    runRecords.sort { $0.updatedAt > $1.updatedAt }
    let runs = Array(runRecords.prefix(60))
    return GraphQLOpsOverviewPayload(
      profile: profileName.rawValue,
      revision: revision,
      workflows: workflows,
      workflowsTruncated: workflowSources.count > sources.count,
      instances: overviewInstances,
      runs: runs.map(\.run),
      runsTruncated: runRecords.count > runs.count,
      diagnostics: Array(diagnostics.prefix(20))
    )
  }

  // MARK: - Instance projection

  private func consoleInstance(_ instance: WorkflowInstance) -> GraphQLConsoleInstanceDTO {
    let snapshot = runtimeSnapshot(instance.identity)
    let preference = instance.preference
    let effectiveEnvironment = environment(instance)
    return GraphQLConsoleInstanceDTO(
      id: instance.identity,
      sourceId: instance.sourceIdentity,
      isDefault: instance.isDefault,
      name: instance.displayName,
      workflowId: instance.source.workflowId,
      source: instance.source.sourceDescription,
      sourceKind: instance.source.packageDirectory == nil ? "directory" : "package",
      status: snapshot.status.rawValue,
      statusDetail: snapshot.detail,
      active: preference.active,
      enabledAtLaunch: preference.enabledAtLaunch,
      workingDirectory: preference.workingDirectory,
      environmentFilePath: preference.environmentFilePath,
      environmentVariables: maskedEnvironmentVariables(preference.environmentVariables),
      requiredEnvironment: instance.candidate.requiredEnvironment.map { requirement in
        let value = effectiveEnvironment[requirement.name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GraphQLConsoleRequiredEnvironmentDTO(
          name: requirement.name,
          description: requirement.description,
          secret: requirement.secret,
          source: "workflow",
          present: value?.isEmpty == false
        )
      },
      workflowVariables: preference.defaultVariables,
      nodePatchCount: preference.nodePatches.count,
      nodePatches: preference.nodePatches.mapValues { .object($0.jsonObject) },
      eventSources: instance.source.eventSources.map {
        GraphQLConsoleInstanceEventSourceDTO(id: $0.id, kind: $0.kind)
      }
    )
  }

  private func missingSourceInstance(
    identity: String,
    preference: RielaAppDaemonWorkflowPreference
  ) -> GraphQLConsoleInstanceDTO {
    let sourceIdentity = preference.sourceIdentity ?? identity
    let fallbackName = identity == sourceIdentity ? "標準設定" : identity
    let name = preference.displayName?.isEmpty == false ? preference.displayName ?? fallbackName : fallbackName
    return GraphQLConsoleInstanceDTO(
      id: identity,
      sourceId: sourceIdentity,
      isDefault: identity == sourceIdentity,
      name: name,
      workflowId: sourceIdentity,
      source: "Missing source: \(sourceIdentity)",
      sourceKind: "missing",
      status: "needsSource",
      statusDetail: "The configured workflow source is unavailable. Relink it in the native app.",
      active: preference.active,
      enabledAtLaunch: preference.enabledAtLaunch,
      workingDirectory: preference.workingDirectory,
      environmentFilePath: preference.environmentFilePath,
      environmentVariables: maskedEnvironmentVariables(preference.environmentVariables),
      requiredEnvironment: [],
      workflowVariables: preference.defaultVariables,
      nodePatchCount: preference.nodePatches.count,
      nodePatches: preference.nodePatches.mapValues { .object($0.jsonObject) },
      eventSources: []
    )
  }

  private func maskedEnvironmentVariables(
    _ values: [String: String]
  ) -> [GraphQLConsoleEnvironmentVariableDTO] {
    values.keys.sorted().map {
      GraphQLConsoleEnvironmentVariableDTO(name: $0, isSet: true, masked: "••••••••")
    }
  }
}

/// Adapts the `@MainActor` provider to the `Sendable` GraphQL provider
/// protocol; the console host owns main-actor state.
public struct RielaConsoleGraphQLProviderAdapter: GraphQLConsoleProviding {
  private let build: @Sendable () async -> RielaConsoleGraphQLProvider

  public init(build: @escaping @Sendable () async -> RielaConsoleGraphQLProvider) {
    self.build = build
  }

  public func consoleInstances() async throws -> GraphQLConsoleInstanceListPayload {
    await build().consoleInstanceList()
  }

  public func consoleInstance(identity: String) async throws -> GraphQLConsoleInstancePayload {
    await build().consoleInstanceDetail(identity: identity)
  }

  public func opsOverview() async throws -> GraphQLOpsOverviewPayload {
    await build().opsOverviewPayload()
  }
}
