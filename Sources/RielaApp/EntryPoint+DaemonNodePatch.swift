#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore

extension RielaApp {
  func saveDaemonKaibaNodeBinding(
    identity: String,
    nodeId: String,
    instanceID: String?,
    hasAuthoredBinding: Bool
  ) -> Bool {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return false
    }
    var patch = resolved.preference.nodePatches[nodeId] ?? RielaAppDaemonWorkflowNodePatch()
    patch.kaibaInstanceId = instanceID
    // The AppKit editor has already loaded the authored workflow off-main-actor.
    // A reset only needs an explicit JSON null when it masks that binding.
    patch.clearsKaibaInstanceId = instanceID == nil && hasAuthoredBinding
    return saveDaemonNodePatch(identity: identity, nodeId: nodeId, patch: patch)
  }

  func saveDaemonNodePatch(
    identity: String,
    nodeId: String,
    patch: RielaAppDaemonWorkflowNodePatch?
  ) -> Bool {
    guard let resolved = resolveDaemonWorkflowInstance(identity: identity) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return false
    }
    let didSave = updateDaemonPreference(identity: identity) { preference in
      preference.sourceIdentity = resolved.instance.instance.source.id
      if let patch, !patch.isEmpty {
        preference.nodePatches[nodeId] = patch
      } else {
        preference.nodePatches.removeValue(forKey: nodeId)
      }
    }
    if didSave {
      restartActiveDaemonWorkflowAfterConfigurationChange(
        identity: identity,
        changeDescription: "node patch"
      )
    }
    return didSave
  }
}
#endif
