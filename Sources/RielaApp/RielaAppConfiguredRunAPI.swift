#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCLI
import RielaCore
import RielaGraphQL
import RielaServer

extension RielaApp {
  func webConfiguredRunResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? {
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    guard parts.count == 5, Array(parts.prefix(3)) == ["api", "v1", "instances"], parts[4] == "runs" else { return nil }
    guard request.method == "POST", let identity = parts[3].removingPercentEncoding else {
      return .json(status: 400, .object(["error": .object(["code": .string("invalid_configured_run")])]))
    }
    return await controlService.handle(.run(identity: identity, body: request.body),
      profile: request.headers["x-riela-profile"]).httpResponse
  }
}
#endif
