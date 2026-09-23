#if os(macOS)
import RielaServer

extension RielaApp {
  func webWorkflowEditorNodeSettings(request: RielaHTTPRequest) async -> RielaHTTPResponse {
    await webWorkflowHandler.webWorkflowEditorNodeSettings(request: request)
  }
}
#endif
