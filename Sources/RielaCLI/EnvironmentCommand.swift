import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct EnvironmentArguments: ParsableArguments {
  @Argument var action: String
  @Option var instance: String
  @Option var profile: String
  @Option var server: String = "http://127.0.0.1:8787"
  @Option var output: String = "json"
}

private struct EnvironmentBootstrap: Decodable {
  var profile: String
  var revision: Int
  var csrfToken: String
}

struct EnvironmentCommand {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
  var transport: Transport = { request in
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration, delegate: NoEnvironmentRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  func run(_ arguments: [String]) async -> CLICommandResult {
    if arguments.contains("--help") || arguments.contains("-h") {
      return CLICommandResult(exitCode: .success, stdout: EnvironmentArguments.helpMessage() + "\n")
    }
    do {
      let args = try EnvironmentArguments.parse(arguments)
      guard ["status", "reload"].contains(args.action), args.output == "json",
        !args.instance.isEmpty, args.instance.utf8.count <= 1024,
        !args.profile.isEmpty, args.profile.utf8.count <= 128,
        let base = URLComponents(string: args.server), let scheme = base.scheme, let host = base.host,
        ["http", "https"].contains(scheme), base.user == nil, base.password == nil,
        base.query == nil, base.fragment == nil, base.path.isEmpty || base.path == "/",
        scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
        throw CLIUsageError("environment_invalid_options")
      }
      func url(_ path: String) throws -> URL {
        var next = base; next.percentEncodedPath = path
        guard let url = next.url else { throw CLIUsageError("environment_invalid_options") }
        return url
      }
      let bootstrap = try JSONDecoder().decode(EnvironmentBootstrap.self,
        from: await fetch(URLRequest(url: url("/api/v1/bootstrap"))))
      guard bootstrap.profile == args.profile else { throw CLIUsageError("environment_profile_conflict") }
      let id = args.instance.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
      let path = "/api/v1/instances" + "/" + id
      if args.action == "reload" {
        var request = URLRequest(url: try url(path + "/actions"))
        request.httpMethod = "POST"
        request.setValue(args.server.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        request.setValue(bootstrap.csrfToken, forHTTPHeaderField: "x-riela-csrf")
        request.setValue(args.profile, forHTTPHeaderField: "x-riela-profile")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "reloadEnvironment",
          "expectedProfile": args.profile, "expectedRevision": bootstrap.revision])
        _ = try await fetch(request)
      }
      var statusRequest = URLRequest(url: try url(path + "/environment"))
      statusRequest.setValue(args.profile, forHTTPHeaderField: "x-riela-profile")
      let status = try Self.decodeStatus(try await fetch(statusRequest))
      return CLICommandResult(exitCode: .success, stdout: try Self.render(status))
    } catch let failure as EnvironmentHTTPFailure {
      return CLICommandResult(exitCode: .failure, stdout: failure.status.map { (try? Self.render($0)) ?? "" } ?? "",
        stderr: failure.code + "\n")
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .failure, stderr: error.message + "\n")
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "environment_request_failed\n")
    }
  }

  /// Re-encodes the finite status contract; never forwards arbitrary server output.
  private static func render(_ status: EnvironmentClientStatus) throws -> String {
    (String(data: try JSONEncoder().encode(status), encoding: .utf8) ?? "") + "\n"
  }

  private static func decodeStatus(_ data: Data) throws -> EnvironmentClientStatus {
    if let direct = try? JSONDecoder().decode(EnvironmentClientStatus.self, from: data) { return direct }
    struct Envelope: Decodable { var environment: EnvironmentClientStatus }
    return try JSONDecoder().decode(Envelope.self, from: data).environment
  }

  /// Maps a non-2xx response to a safe code: the status body's `lastError`
  /// (422 reload failures), else an `{"error":{"code":...}}` envelope code,
  /// else `environment_http_<status>`. Only safe-code shaped strings are used.
  static func failure(status: Int, body: Data) -> EnvironmentHTTPFailure {
    let fallback = "environment_http_" + String(status)
    guard body.count <= 1_048_576 else { return EnvironmentHTTPFailure(code: fallback, status: nil) }
    if let decoded = try? decodeStatus(body), let code = decoded.lastError {
      return EnvironmentHTTPFailure(code: code, status: decoded)
    }
    if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
      let code = EnvironmentClientStatus.safeCode(envelope.error.code) {
      return EnvironmentHTTPFailure(code: code, status: nil)
    }
    return EnvironmentHTTPFailure(code: fallback, status: nil)
  }

  private func fetch(_ request: URLRequest) async throws -> Data {
    let (data, status) = try await transport(request)
    guard (200..<300).contains(status) else { throw Self.failure(status: status, body: data) }
    guard data.count <= 1_048_576 else { throw CLIUsageError("environment_response_too_large") }
    return data
  }
}

private struct ErrorEnvelope: Decodable {
  struct Detail: Decodable { var code: String }
  var error: Detail
}

struct EnvironmentHTTPFailure: Error {
  var code: String
  var status: EnvironmentClientStatus?
}

/// Client view of `RuntimeEnvironmentStatus`. `readiness` and `lastError` are
/// decoded as strings so codes added by a newer server (for example
/// `environment_restart_required`) print verbatim instead of failing decode;
/// values that are not safe-code shaped are replaced, never forwarded.
struct EnvironmentClientStatus: Codable, Equatable, Sendable {
  var names: [String]
  var configuredNames: [String]
  var missingNames: [String]
  var sourceIDs: [String]
  var generation: UInt64
  var readiness: String
  var lastError: String?

  private enum CodingKeys: String, CodingKey {
    case names, configuredNames, missingNames, sourceIDs, generation, readiness, lastError
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    names = try container.decode([String].self, forKey: .names)
    configuredNames = try container.decode([String].self, forKey: .configuredNames)
    missingNames = try container.decode([String].self, forKey: .missingNames)
    sourceIDs = try container.decode([String].self, forKey: .sourceIDs)
    generation = try container.decode(UInt64.self, forKey: .generation)
    readiness = Self.safeCode(try container.decode(String.self, forKey: .readiness)) ?? "unknown"
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
      .map { Self.safeCode($0) ?? "environment_request_failed" }
  }

  /// Lowercase snake-case token of at most 96 bytes, or nil.
  static func safeCode(_ value: String) -> String? {
    guard (1...96).contains(value.utf8.count), let first = value.utf8.first, (97...122).contains(first),
      value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
    return value
  }
}

private final class NoEnvironmentRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
