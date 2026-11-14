import Foundation
import RielaAppSupport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RielaAppAPIFailure: Error {
  var code: String
  var status: Int
  var body: Data
}

struct RielaAppAPIClient: Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
  struct Bootstrap: Decodable {
    var profile: String
    var revision: Int
    var csrfToken: String
  }
  private struct Settings: Decodable { var isEnabled: Bool; var port: Int }
  private struct ErrorEnvelope: Decodable { var error: AppErrorDetail }

  var endpoint: URL
  var profile: String
  var transport: Transport = { request in
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration, delegate: AppNoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  static func appRoot(environment: [String: String]) -> URL {
    if let root = environment["RIELA_APP_ROOT"], !root.isEmpty {
      return URL(fileURLWithPath: root, isDirectory: true)
    }
    return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
      .appendingPathComponent(".riela/rielaapp", isDirectory: true)
  }

  static func resolveEndpoint(server: String?, appRoot: URL, environment: [String: String]) throws -> URL {
    if let server {
      guard let parts = URLComponents(string: server), let scheme = parts.scheme, let host = parts.host,
        ["http", "https"].contains(scheme), parts.user == nil, parts.password == nil,
        parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
        scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
        let url = parts.url else { throw CLIUsageError("app_invalid_server") }
      return url
    }
    #if !os(macOS)
    throw CLIUsageError("app_server_required")
    #else
    let url = appRoot.appendingPathComponent("web-server.json")
    let settings = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
    let port = settings.flatMap { (1...65535).contains($0.port) ? $0.port : nil } ?? 19091
    guard let endpoint = URL(string: "http://127.0.0.1:\(port)") else { throw CLIUsageError("app_invalid_server") }
    return endpoint
    #endif
  }

  static func expectedProfile(explicit: String?, appRoot: URL) throws -> String {
    let url = appRoot.appendingPathComponent("active-profile.json")
    let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RielaAppProfileState.self, from: $0) }
    let profile = explicit ?? stored?.activeProfileName.rawValue ?? "default"
    guard !profile.isEmpty, profile.utf8.count <= 128 else { throw CLIUsageError("app_invalid_profile") }
    return profile
  }

  func bootstrap() async throws -> Bootstrap {
    let result = try JSONDecoder().decode(Bootstrap.self, from: await fetch(URLRequest(url: url("/api/v1/bootstrap"))))
    guard result.profile == profile else { throw RielaAppAPIFailure(code: "app_profile_conflict", status: 0, body: Data()) }
    return result
  }

  func get(_ path: String) async throws -> Data {
    var request = URLRequest(url: try url(path))
    request.setValue(profile, forHTTPHeaderField: "x-riela-profile")
    return try await fetch(request)
  }

  func post(_ path: String, body: [String: Any], bootstrap: Bootstrap) async throws -> Data {
    var request = URLRequest(url: try url(path))
    request.httpMethod = "POST"
    request.setValue(endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
    request.setValue(bootstrap.csrfToken, forHTTPHeaderField: "x-riela-csrf")
    request.setValue(profile, forHTTPHeaderField: "x-riela-profile")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return try await fetch(request)
  }

  private func url(_ path: String) throws -> URL {
    guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw CLIUsageError("app_invalid_server") }
    parts.percentEncodedPath = path
    guard let result = parts.url else { throw CLIUsageError("app_invalid_server") }
    return result
  }

  private func fetch(_ request: URLRequest) async throws -> Data {
    let data: Data
    let status: Int
    do {
      (data, status) = try await transport(request)
    } catch {
      throw RielaAppAPIFailure(code: "app_unreachable", status: 0, body: Data())
    }
    guard data.count <= 1_048_576 else { throw RielaAppAPIFailure(code: "app_response_too_large", status: status, body: Data()) }
    guard (200..<300).contains(status) else { throw Self.failure(status: status, body: data) }
    return data
  }

  static func failure(status: Int, body: Data) -> RielaAppAPIFailure {
    guard body.count <= 1_048_576 else {
      return RielaAppAPIFailure(code: "app_response_too_large", status: status, body: Data())
    }
    let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
    let code = envelope.flatMap { EnvironmentClientStatus.safeCode($0.error.code) } ?? "app_http_\(status)"
    return RielaAppAPIFailure(code: code, status: status, body: body)
  }
}

private struct AppErrorDetail: Decodable { var code: String }

private final class AppNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
