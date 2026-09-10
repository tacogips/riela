#if os(macOS)
import RielaServer

extension RielaApp {
  func webWorkflowEditorLaunch(request: RielaHTTPRequest) -> RielaHTTPResponse {
    webWorkflowHandler.webWorkflowEditorLaunch(request: request)
  }
}
#endif
