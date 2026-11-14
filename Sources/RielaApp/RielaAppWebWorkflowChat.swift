#if os(macOS)
import RielaServer

extension RielaApp {
  func webWorkflowEditorGeneration(request: RielaHTTPRequest) async -> RielaHTTPResponse {
    await webWorkflowHandler.webWorkflowEditorGeneration(request: request)
  }
}
#endif
