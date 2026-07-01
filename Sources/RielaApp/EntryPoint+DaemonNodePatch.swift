#if os(macOS)
import Foundation
import RielaAppSupport

extension RielaApp {
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
