import Foundation
import KaibaClient

public struct KaibaReadinessService: Sendable {
  public init() {}

  public func test(_ client: KaibaClient) async throws -> KaibaInstanceLastTest {
    let result = try await client.probeReadiness()
    let status: KaibaInstanceLastTestStatus
    let code: String?
    switch result.status {
    case .ready:
      status = .ready
      code = nil
    case .authFailed:
      status = .authFailed
      code = "kaiba_auth_failed"
    case .connectionFailed:
      status = .connectionFailed
      code = "kaiba_connection_failed"
    case .serverRejected:
      status = .incompatible
      code = "server_rejected"
    case .incompatibleResponse:
      status = .incompatible
      code = "incompatible_response"
    }
    return KaibaInstanceLastTest(status: status, code: code, attemptedAt: Date())
  }
}
