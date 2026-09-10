#if os(macOS)
import RielaServer

extension RielaApp {
  func webWorkflowEditorRunEvidence(request: RielaHTTPRequest) -> RielaHTTPResponse {
    webWorkflowHandler.webWorkflowEditorRunEvidence(request: request)
  }
}
#endif
