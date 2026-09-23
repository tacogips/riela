import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DistributedWorkerHTTPClient: Sendable {
  private let endpoint: URL
  private let token: String

  public init(controllerURL: URL, token: String, allowInsecureHTTP: Bool = false) throws {
    guard let parts = URLComponents(url: controllerURL, resolvingAgainstBaseURL: false),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
      parts.scheme == "https" || parts.scheme == "http",
      token.utf8.count >= 32, token.utf8.count <= 256,
      token.utf8.allSatisfy({ (33...126).contains($0) }) else {
      throw DistributedWorkerTransportError.invalidEndpoint
    }
    guard parts.scheme == "https" || allowInsecureHTTP || ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) else {
      throw DistributedWorkerTransportError.insecureEndpoint
    }
    self.endpoint = controllerURL.appendingPathComponent("distributed/v1/worker")
    self.token = token
  }

  public func send(_ message: DistributedWorkerRequest) async throws -> DistributedWorkerResponse {
    let data = try JSONEncoder().encode(message)
    guard data.count <= DistributedWorkerHTTPRouter.maximumBodyBytes else { throw DistributedWorkerTransportError.oversizedMessage }
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    let transfer = DistributedWorkerHTTPTransfer()
    let response = try await withTaskCancellationHandler {
      try await transfer.run(request)
    } onCancel: {
      transfer.cancel()
    }
    do { return try JSONDecoder().decode(DistributedWorkerResponse.self, from: response) } catch { throw DistributedWorkerTransportError.invalidResponse }
  }
}

/// One transfer per instance. Delegate collection bounds memory on both macOS
/// and FoundationNetworking, and rejects redirects before forwarding credentials.
private final class DistributedWorkerHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var cancelled = false
  private var bytes = Data()
  private var failure: DistributedWorkerTransportError?

  func run(_ request: URLRequest) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      guard !cancelled else {
        lock.unlock()
        continuation.resume(throwing: CancellationError())
        return
      }
      self.continuation = continuation
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      configuration.urlCache = nil
      configuration.timeoutIntervalForResource = 20
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session
      let task = session.dataTask(with: request)
      self.task = task
      task.resume()
      lock.unlock()
    }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let task = task
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    if let response = response as? HTTPURLResponse {
      if response.statusCode != 200 {
        failure = .rejected(status: response.statusCode)
      } else if response.expectedContentLength > Int64(DistributedWorkerHTTPRouter.maximumBodyBytes) {
        failure = .oversizedMessage
      } else if response.mimeType != "application/json" {
        failure = .invalidResponse
      }
    } else { failure = .invalidResponse }
    let allowed = failure == nil
    lock.unlock()
    completionHandler(allowed ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    let oversized = data.count > DistributedWorkerHTTPRouter.maximumBodyBytes - bytes.count
    if oversized { failure = .oversizedMessage } else { bytes.append(data) }
    lock.unlock()
    if oversized { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    let result: Result<Data, Error>
    if cancelled {
      result = .failure(CancellationError())
    } else if let failure {
      result = .failure(failure)
    } else if error != nil {
      result = .failure(DistributedWorkerTransportError.networkFailure)
    } else {
      result = .success(bytes)
    }
    self.task = nil
    self.session = nil
    lock.unlock()
    session.finishTasksAndInvalidate()
    continuation?.resume(with: result)
  }
}
