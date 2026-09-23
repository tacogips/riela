import Foundation
import RielaCore

public struct DeterministicServerHTTPAdapter: RielaHTTPRouteHandling {
  public var routeHandler: any ServerRouteHandling
  public var context: ServerRequestContext

  public init(
    routeHandler: any ServerRouteHandling = DeterministicServerRouteHandler(),
    context: ServerRequestContext = ServerRequestContext()
  ) {
    self.routeHandler = routeHandler
    self.context = context
  }

  public func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    let descriptor = await routeHandler.route(
      ServerRequestEnvelope(
        method: request.method,
        path: request.path,
        headers: request.headers,
        body: request.body.isEmpty ? nil : request.body,
        query: request.query
      ),
      context: context
    )
    let body = (try? JSONEncoder.sorted.encode(JSONValue.object(descriptor.body))) ?? Data("{}".utf8)
    return RielaHTTPResponse(
      status: descriptor.status,
      headers: ["Content-Type": descriptor.contentType + "; charset=utf-8"],
      body: body
    )
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}
