import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaAppSupport

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
      let path = "/api/v1/instances/" + id
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
      let data = try await fetch(statusRequest)
      let status: RuntimeEnvironmentStatus
      if let direct = try? JSONDecoder().decode(RuntimeEnvironmentStatus.self, from: data) {
        status = direct
      } else {
        struct Envelope: Decodable { var environment: RuntimeEnvironmentStatus }
        status = try JSONDecoder().decode(Envelope.self, from: data).environment
      }
      // Re-encode the finite status contract; never forward arbitrary server output.
      return CLICommandResult(exitCode: .success, stdout: (String(data: try JSONEncoder().encode(status), encoding: .utf8) ?? "") + "\n")
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .failure, stderr: error.message + "\n")
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "environment_request_failed\n")
    }
  }

  private func fetch(_ request: URLRequest) async throws -> Data {
    let (data, status) = try await transport(request)
    guard (200..<300).contains(status) else { throw CLIUsageError("environment_http_" + String(status)) }
    guard data.count <= 1_048_576 else { throw CLIUsageError("environment_response_too_large") }
    return data
  }
}

private final class NoEnvironmentRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
