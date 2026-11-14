import Foundation

/// Limits apply before authentication, including clients that send no bytes.
public struct RielaHTTPConnectionLimits: Sendable {
  let maximumConnections: Int
  let requestReadTimeout: TimeInterval

  public init(maximumConnections: Int = 128, requestReadTimeout: TimeInterval = 15) {
    self.maximumConnections = max(1, maximumConnections)
    self.requestReadTimeout = requestReadTimeout.isFinite ? max(0.01, min(300, requestReadTimeout)) : 15
  }
}
