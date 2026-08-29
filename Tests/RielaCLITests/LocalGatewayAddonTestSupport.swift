import Foundation
import RielaCore
@testable import RielaCLI

/// Stands in for a gateway's GraphQL runtime in add-on tests. The gateways are
/// linked into this process, so an add-on test that reached the real runtime
/// would need a live account; recording the call instead keeps the assertions
/// on what riela is responsible for — the tier it pinned, the document and
/// variables it rendered, and the environment it let the gateway see.
final class RecordingGatewayGraphQLRunner: @unchecked Sendable {
  struct Call: Sendable {
    var tier: String
    var document: String
    var variablesJSON: String?
    var environment: [String: String]
  }

  private let lock = NSLock()
  private let response: String
  private let failure: (any Error)?
  private var calls: [Call] = []

  init(response: String = "{}", failure: (any Error)? = nil) {
    self.response = response
    self.failure = failure
  }

  var runner: LocalGatewayGraphQLRunner {
    { [self] tier, document, variablesJSON, environment in
      lock.withLock {
        calls.append(Call(
          tier: tier,
          document: document,
          variablesJSON: variablesJSON,
          environment: environment
        ))
      }
      if let failure { throw failure }
      return response
    }
  }

  func lastCall() -> Call? { lock.withLock { calls.last } }
  func allCalls() -> [Call] { lock.withLock { calls } }
}

/// The same seam for google-documents-gateway, whose surface is CLI arguments
/// rather than a GraphQL document.
final class RecordingGoogleDocumentsGatewayRunner: @unchecked Sendable {
  struct Call: Sendable {
    var tier: String
    var arguments: [String]
    var environment: [String: String]
  }

  private let lock = NSLock()
  private let response: String
  private let failure: (any Error)?
  private var calls: [Call] = []

  init(response: String = #"{"ok":true,"data":{}}"#, failure: (any Error)? = nil) {
    self.response = response
    self.failure = failure
  }

  var runner: GoogleDocumentsGatewayRunner {
    { [self] tier, arguments, environment in
      lock.withLock {
        calls.append(Call(tier: tier, arguments: arguments, environment: environment))
      }
      if let failure { throw failure }
      return response
    }
  }

  func lastCall() -> Call? { lock.withLock { calls.last } }
  func allCalls() -> [Call] { lock.withLock { calls } }
}
