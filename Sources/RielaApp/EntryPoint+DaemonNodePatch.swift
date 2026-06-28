#if os(macOS)
import Foundation
import RielaAppSupport

extension RielaApp {
  func saveDaemonNodePatch(
    identity: String,
    nodeId: String,
    patch: RielaAppDaemonWorkflowNodePatch?
  ) -> Bool {
    updateDaemonPreference(identity: identity) { preference in
      if let patch, !patch.isEmpty {
        preference.nodePatches[nodeId] = patch
      } else {
        preference.nodePatches.removeValue(forKey: nodeId)
      }
    }
  }
}
#endif
