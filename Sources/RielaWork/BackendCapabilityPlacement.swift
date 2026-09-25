import Foundation
import RielaCore

public struct BackendPlacementChoice: Codable, Equatable, Sendable {
  public var provenance: WorkflowRequirementProvenance
  public var hostId: String
  public var backend: NodeExecutionBackend?
  public var model: String?
  public var source: BackendCapability.Source?
  public var observedAt: Date?
  public var fresh: Bool
  public var verified: Bool

  public init(
    provenance: WorkflowRequirementProvenance,
    hostId: String,
    backend: NodeExecutionBackend?,
    model: String?,
    source: BackendCapability.Source?,
    observedAt: Date?,
    fresh: Bool,
    verified: Bool
  ) {
    self.provenance = provenance
    self.hostId = hostId
    self.backend = backend
    self.model = model
    self.source = source
    self.observedAt = observedAt
    self.fresh = fresh
    self.verified = verified
  }
}

public struct BackendPlacementFailure: Codable, Equatable, Sendable {
  public var provenance: WorkflowRequirementProvenance
  public var reason: String

  public init(provenance: WorkflowRequirementProvenance, reason: String) {
    self.provenance = provenance
    self.reason = reason
  }
}

public struct BackendCapabilityPlacementResult: Codable, Equatable, Sendable {
  public var choices: [BackendPlacementChoice]
  public var failures: [BackendPlacementFailure]

  public var complete: Bool { failures.isEmpty }
}

public struct BackendCapabilityPlacementResolver: Sendable {
  public var maximumAge: TimeInterval

  public init(maximumAge: TimeInterval = 300) {
    self.maximumAge = maximumAge
  }

  public func resolve(
    requirements: [WorkflowBackendRequirement],
    local: HostCapabilitySnapshot,
    workers: [HostCapabilitySnapshot],
    assignments: [WorkflowRequirementProvenance: DistributedWorkerTarget] = [:],
    now: Date = Date()
  ) -> BackendCapabilityPlacementResult {
    var choices: [BackendPlacementChoice] = []
    var failures: [BackendPlacementFailure] = []
    let workerIdCounts = Dictionary(workers.map { ($0.hostId, 1) }, uniquingKeysWith: +)
    let eligibleWorkers = workers.filter {
      $0.hostId != local.hostId && workerIdCounts[$0.hostId] == 1
    }
    var remainingCapacity = Dictionary(uniqueKeysWithValues: ([local] + eligibleWorkers).compactMap { host in
      host.capacity.map { (host.hostId, $0) }
    })
    var admittedHosts: Set<String> = []
    for requirement in requirements {
      for provenance in requirement.provenance {
        let candidates = candidates(
          local: local,
          workers: eligibleWorkers,
          assignment: assignments[provenance],
          remainingCapacity: remainingCapacity,
          admittedHosts: admittedHosts
        )
        guard let choice = candidates.lazy.compactMap({ host in
          choice(for: requirement, provenance: provenance, host: host, now: now)
        }).first else {
          failures.append(BackendPlacementFailure(
            provenance: provenance,
            reason: failureReason(for: requirement)
          ))
          continue
        }
        choices.append(choice)
        if admittedHosts.insert(choice.hostId).inserted, let capacity = remainingCapacity[choice.hostId] {
          remainingCapacity[choice.hostId] = capacity - 1
        }
      }
    }
    return BackendCapabilityPlacementResult(choices: choices, failures: failures)
  }

  private func candidates(
    local: HostCapabilitySnapshot,
    workers: [HostCapabilitySnapshot],
    assignment: DistributedWorkerTarget?,
    remainingCapacity: [String: Int],
    admittedHosts: Set<String>
  ) -> [HostCapabilitySnapshot] {
    if let assignment {
      return workers.filter { host in
        host.live && (admittedHosts.contains(host.hostId) || (remainingCapacity[host.hostId] ?? 0) > 0)
          && (assignment.workerId == nil || assignment.workerId == host.hostId)
          && (assignment.group == nil || host.groups.contains(assignment.group ?? ""))
      }.sorted { $0.hostId < $1.hostId }
    }
    let localCandidate = local.live
      && (admittedHosts.contains(local.hostId) || (remainingCapacity[local.hostId] ?? 1) > 0) ? [local] : []
    return localCandidate + workers.filter {
      $0.live && (admittedHosts.contains($0.hostId) || (remainingCapacity[$0.hostId] ?? 0) > 0)
    }.sorted { $0.hostId < $1.hostId }
  }

  private func choice(
    for requirement: WorkflowBackendRequirement,
    provenance: WorkflowRequirementProvenance,
    host: HostCapabilitySnapshot,
    now: Date
  ) -> BackendPlacementChoice? {
    let hostFactsObservedAt = host.capabilitiesObservedAt
    let hostFactsAge = hostFactsObservedAt.map { now.timeIntervalSince($0) }
    let hostFactsAreFresh = hostFactsAge.map { $0 >= 0 && $0 < maximumAge } ?? false
    if !requirement.requiredEnvironment.isEmpty || requirement.addonExecutable != nil
      || backendCandidates(for: requirement).isEmpty {
      guard hostFactsAreFresh else { return nil }
    }
    guard requirement.requiredEnvironment.allSatisfy({ host.environment[$0] == true }) else { return nil }
    if let executable = requirement.addonExecutable, host.addonExecutables[executable] != true { return nil }
    if backendCandidates(for: requirement).isEmpty {
      return BackendPlacementChoice(
        provenance: provenance,
        hostId: host.hostId,
        backend: nil,
        model: nil,
        source: nil,
        observedAt: hostFactsObservedAt,
        fresh: true,
        verified: true
      )
    }
    for backend in backendCandidates(for: requirement) {
      guard let capability = host.capability(for: backend) else { continue }
      guard capability.executableAvailable != false else { continue }
      let alternativeEnvironmentNames = Set((capability.requiredEnvironmentAlternatives ?? []).flatMap { $0 })
      let requiredEnvironmentIsPresent = capability.requiredEnvironment
        .filter { !alternativeEnvironmentNames.contains($0.key) }
        .allSatisfy { name, present in present && host.environment[name] == true }
      guard requiredEnvironmentIsPresent else { continue }
      let alternativesArePresent = (capability.requiredEnvironmentAlternatives ?? []).allSatisfy { alternatives in
        let observedPresence = alternatives.compactMap { name in
          capability.requiredEnvironment[name].map { (name, $0) }
        }
        return observedPresence.isEmpty || observedPresence.contains {
          $0.1 && host.environment[$0.0] == true
        }
      }
      guard alternativesArePresent else { continue }
      let fresh = capability.isFresh(at: now, maximumAge: maximumAge)
      let explicitlyEnabled = capability.source != .observed && capability.availability == .available
      let usesHostEnvironment = !capability.requiredEnvironment.isEmpty
        || !(capability.requiredEnvironmentAlternatives ?? []).isEmpty
      guard !usesHostEnvironment || hostFactsAreFresh else { continue }
      guard capability.availability == .available, fresh || explicitlyEnabled else { continue }
      guard explicitlyEnabled || capability.authentication == .available else { continue }
      let model = requirement.policy?.modelByBackend[backend] ?? requirement.explicitModel
      if let model, let models = capability.models, !models.contains(model) { continue }
      let verified = fresh && capability.authentication == .available
        && (model == nil || capability.models?.isEmpty == false)
      return BackendPlacementChoice(
        provenance: provenance,
        hostId: host.hostId,
        backend: backend,
        model: model,
        source: capability.source,
        observedAt: capability.observedAt,
        fresh: fresh,
        verified: verified
      )
    }
    return nil
  }

  private func backendCandidates(for requirement: WorkflowBackendRequirement) -> [NodeExecutionBackend] {
    if let pin = requirement.pin { return [pin] }
    return requirement.policy?.orderedCandidates() ?? []
  }

  private func backendNames(for requirement: WorkflowBackendRequirement) -> [String] {
    backendCandidates(for: requirement).map(\.rawValue)
  }

  private func failureReason(for requirement: WorkflowBackendRequirement) -> String {
    if backendCandidates(for: requirement).isEmpty, let executable = requirement.addonExecutable {
      return "addon-executable-unavailable: \(executable)"
    }
    return "backend-unavailable: \(backendNames(for: requirement).joined(separator: ","))"
  }
}
