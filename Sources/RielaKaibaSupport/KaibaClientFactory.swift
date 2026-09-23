import Foundation
import KaibaClient

public enum KaibaClientFactoryError: Error, Equatable, Sendable {
  case missingCredential
  case invalidCredential
  case invalidConfiguration

  public var code: String {
    switch self {
    case .missingCredential: "missing_kaiba_credential"
    case .invalidCredential: "invalid_kaiba_credential"
    case .invalidConfiguration: "invalid_kaiba_instance"
    }
  }
}

public struct KaibaClientFactory: Sendable {
  public typealias TransportFactory = @Sendable () -> any KaibaHTTPTransporting

  private let transportFactory: TransportFactory

  public init(transportFactory: @escaping TransportFactory = { URLSessionKaibaHTTPTransport() }) {
    self.transportFactory = transportFactory
  }

  public func makeClient(
    instance: KaibaInstance,
    environment: [String: String]
  ) throws -> KaibaClient {
    let authentication: KaibaAuthentication
    switch instance.authentication {
    case .unauthenticated:
      authentication = .unauthenticated
    case let .bearer(environmentVariable):
      guard let rawToken = environment[environmentVariable], !rawToken.isEmpty else {
        throw KaibaClientFactoryError.missingCredential
      }
      do {
        authentication = .bearer(try KaibaBearerToken(rawToken))
      } catch {
        throw KaibaClientFactoryError.invalidCredential
      }
    }
    do {
      let configuration = try KaibaClientConfiguration(
        transportSecurity: instance.allowInsecureHTTP ? .allowInsecureRemoteHTTP : .secureByDefault,
        allowRemoteUnauthenticated: instance.allowRemoteUnauthenticated
      )
      guard let endpoint = URL(string: instance.endpoint) else {
        throw KaibaClientFactoryError.invalidConfiguration
      }
      return try KaibaClient(endpoint: endpoint, authentication: authentication, configuration: configuration, transport: transportFactory())
    } catch let error as KaibaClientFactoryError {
      throw error
    } catch {
      throw KaibaClientFactoryError.invalidConfiguration
    }
  }
}
