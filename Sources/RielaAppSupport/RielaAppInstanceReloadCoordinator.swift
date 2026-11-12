import Foundation
import RielaServer

public struct RielaAppInstanceReloadCoordinator: Sendable {
  private let ports: any RielaAppInstanceReloadPorts
  private let makeRequestId: @Sendable () -> String

  public init(ports: any RielaAppInstanceReloadPorts, makeRequestId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
    self.ports = ports
    self.makeRequestId = makeRequestId
  }

  public func reload(identity: String, request: RielaAppInstanceReloadRequest) async -> Result<RielaAppInstanceReloadResponse, RielaAppInstanceReloadError> {
    let instance: RielaAppInstanceReloadInstance
    let candidate: RielaAppInstanceReloadCandidate
    let validated: RielaAppInstanceReloadValidated
    do {
      try await ports.validateRevision(expectedRevision: request.expectedRevision, expectedProfile: request.expectedProfile)
      guard let found = await ports.currentInstance(identity: identity) else {
        return .failure(.init(code: .instanceNotFound))
      }
      instance = found
    } catch {
      return .failure(reloadError(error, fallback: .configurationConflict, committed: false))
    }
    do {
      candidate = try await ports.discoverCandidate(instance: instance, requestedDirectory: request.workflowDirectory)
    } catch {
      return .failure(reloadError(error, fallback: .invalidWorkflowSource, committed: false))
    }
    do {
      validated = try await ports.validate(candidate: candidate, instance: instance)
    } catch {
      return .failure(reloadError(error, fallback: .invalidWorkflowDefinition, committed: false))
    }
    let proposed = RielaAppInstanceStartRecord(workflowDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot,
      eventRootDigest: validated.eventRootDigest, triggerDefaultsFingerprint: validated.triggerDefaultsFingerprint)
    let running = await ports.childRunning(identity: identity)
    let installed = await ports.installedStartRecord(identity: identity)
    let needsRespawn = RielaAppInstanceReloadFingerprint.respawnRequired(childRunning: running, installed: installed, proposed: proposed)
    var heldRequestId: String?
    var handoff = "none"
    if needsRespawn {
      let requestId = makeRequestId()
      do {
        let ack = try await ports.admission(identity: identity, frame: .init(type: "admission-close", requestId: requestId,
          leaseSeconds: WorkflowServeAdmissionWire.defaultLeaseSeconds))
        guard ack.state == .closed else { throw WorkflowServeAdmissionError.noAcknowledgement }
        heldRequestId = requestId
        if ack.running > 0 || ack.queued > 0 {
          if !request.interruptRunning {
            await open(identity: identity, requestId: requestId)
            return .failure(.init(code: .instanceRunInFlight, running: ack.running, queued: ack.queued))
          }
          handoff = "interrupted"
        } else {
          handoff = "completed"
        }
      } catch {
        await open(identity: identity, requestId: requestId)
        guard request.interruptRunning else { return .failure(.init(code: .instanceHandoffUnavailable)) }
        handoff = "interrupted"
      }
    }
    let definition: RielaAppInstanceReloadResponse.Definition
    do {
      definition = try await ports.importDefinition(candidate: candidate, reason: request.reason)
    } catch {
      if let heldRequestId { await open(identity: identity, requestId: heldRequestId) }
      return .failure(reloadError(error, fallback: .definitionStoreFailure, committed: false))
    }
    if candidate.sourceChanged {
      do {
        _ = try await ports.relink(identity: identity, candidate: candidate)
      } catch {
        if let heldRequestId { await open(identity: identity, requestId: heldRequestId) }
        return .failure(.init(code: .configurationIOFailure, committed: true, partial: "definition"))
      }
    }
    await ports.refreshCache()
    var respawned = false
    var runtimeStatus = running ? "running" : "stopped"
    if needsRespawn {
      if let heldRequestId {
        do {
          let ack = try await ports.admission(identity: identity, frame: .init(type: "admission-confirm", requestId: heldRequestId))
          if !request.interruptRunning && (ack.state != .closed || ack.running != 0 || ack.queued != 0) {
            await open(identity: identity, requestId: heldRequestId)
            return .success(await response(identity: identity, candidate: candidate, validated: validated, definition: definition,
              needsRespawn: true, respawned: false, handoff: "lost", runtimeStatus: runtimeStatus))
          }
        } catch {
          await open(identity: identity, requestId: heldRequestId)
          return .success(await response(identity: identity, candidate: candidate, validated: validated, definition: definition,
            needsRespawn: true, respawned: false, handoff: "lost", runtimeStatus: runtimeStatus))
        }
      }
      do {
        runtimeStatus = try await ports.replaceChild(identity: identity, interrupt: request.interruptRunning)
        respawned = true
      } catch {
        if let heldRequestId { await open(identity: identity, requestId: heldRequestId) }
        return .failure(reloadError(error, fallback: .instanceStartFailed, committed: true))
      }
    }
    return .success(await response(identity: identity, candidate: candidate, validated: validated, definition: definition,
      needsRespawn: needsRespawn, respawned: respawned, handoff: handoff, runtimeStatus: runtimeStatus))
  }

  private func open(identity: String, requestId: String) async {
    _ = try? await ports.admission(identity: identity, frame: .init(type: "admission-open", requestId: requestId))
  }

  private func reloadError(_ error: Error, fallback: RielaAppInstanceReloadCode, committed: Bool) -> RielaAppInstanceReloadError {
    var result = (error as? RielaAppInstanceReloadError) ?? .init(code: fallback)
    result.committed = committed
    return result
  }

  private func response(identity: String, candidate: RielaAppInstanceReloadCandidate, validated: RielaAppInstanceReloadValidated,
                        definition: RielaAppInstanceReloadResponse.Definition, needsRespawn: Bool, respawned: Bool,
                        handoff: String, runtimeStatus: String) async -> RielaAppInstanceReloadResponse {
    await .init(profile: ports.profile(), revision: ports.liveRevision(), identity: identity, workflowId: validated.workflowId,
      workflowDirectory: candidate.workflowDirectory, sourceChanged: candidate.sourceChanged, definition: definition,
      eventBindings: .init(respawnRequired: needsRespawn, respawned: respawned), handoff: handoff,
      runtimeStatus: runtimeStatus, committed: true)
  }
}
