#if os(macOS)
import RielaAppSupport

struct RielaAppDaemonImportResult {
  var candidate: RielaAppDaemonWorkflowCandidate
  var replacedExisting: Bool
}
#endif
