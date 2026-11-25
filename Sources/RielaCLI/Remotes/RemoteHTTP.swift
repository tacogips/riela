import Foundation
import RielaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RemoteHTTP {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

  static let production: Transport = { request in
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  static func post(endpoint: URL, path: String) throws -> URLRequest {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw invalidResponse }
    components.path = path
    guard let url = components.url else { throw invalidResponse }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  static func send(_ request: URLRequest, via transport: Transport) async throws -> (Data, Int) {
    do {
      return try await transport(request)
    } catch {
      try Task.checkCancellation()
      throw BotStoreError(code: "remote_unreachable", message: "The remote server could not be reached")
    }
  }

  static func safeErrorCode(_ code: String, authorization: String?) -> String? {
    let syntaxIsSafe = !code.isEmpty && code.utf8.count <= 80 && code.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
    }
    guard syntaxIsSafe else { return nil }
    if let authorization, authorization.hasPrefix("Bearer "),
       code.contains(String(authorization.dropFirst(7))) { return nil }
    return code
  }

  static var invalidResponse: BotStoreError {
    BotStoreError(code: "remote_response_invalid", message: "The remote returned an invalid response")
  }

  private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }
}
