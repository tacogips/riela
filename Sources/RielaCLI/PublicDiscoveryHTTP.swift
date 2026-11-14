import CRielaPublicWeb
import Foundation

typealias PublicDiscoveryAuthenticatedTransport = @Sendable (String, Data, Int) async throws -> PublicWebHTTPResponse

enum PublicDiscoveryExecutionContext {
  @TaskLocal static var authenticatedTransport: PublicDiscoveryAuthenticatedTransport?
}

enum PublicDiscoveryHTTP {
  /// The native entry point fixes endpoint, origin, verb and credential header.
  /// It shares public-IP DNS pinning and cancellation, not public-web capability.
  static func exa(token: String, payload: Data, timeoutMs: Int) async throws -> PublicWebHTTPResponse {
    let cancellation = try PublicWebCancellation()
    let task = Task.detached(priority: .utility) {
      var response = token.withCString { token in
        payload.withUnsafeBytes { bytes in
          riela_discovery_exa(token, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count, timeoutMs, cancellation.value)
        }
      }
      defer { riela_web_response_free(&response) }
      switch response.error {
      case 0: break
      case 2: throw PublicWebError.blockedDestination
      case 4: throw PublicWebError.oversized
      case 5: throw CancellationError()
      case 6: throw PublicWebError.timeout
      default: throw PublicWebError.transport
      }
      return PublicWebHTTPResponse(status: Int(response.status), headers: [:],
        body: response.body.map { Data(bytes: $0, count: response.body_length) } ?? Data(),
        url: "https://openrouter.ai/api/v1/chat/completions")
    }
    return try await withTaskCancellationHandler {
      let result = try await task.value; try Task.checkCancellation(); return result
    } onCancel: { cancellation.cancel() }
  }
}
