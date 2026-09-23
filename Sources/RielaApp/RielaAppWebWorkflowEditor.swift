#if os(macOS)
import RielaServer

extension RielaApp {
  func webWorkflowEditorDefinition(request: RielaHTTPRequest) async -> RielaHTTPResponse {
    await webWorkflowHandler.webWorkflowEditorDefinition(request: request)
  }
  func webWorkflowEditableCopy(sourceId: String, request: RielaHTTPRequest) async -> RielaHTTPResponse {
    await webWorkflowHandler.webWorkflowEditableCopy(sourceId: sourceId, request: request)
  }
}
#endif
