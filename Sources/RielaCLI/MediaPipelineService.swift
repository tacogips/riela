import Foundation
import RielaAdapters
import RielaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct MediaPipelineHTTPResponse: Sendable {
  let status: Int
  let body: Data
  let retryAfter: Double?
}
typealias MediaPipelineHTTP = @Sendable (URLRequest) async throws -> MediaPipelineHTTPResponse

let mediaPipelineNativeHTTP: MediaPipelineHTTP = { request in
  let (data, response) = try await URLSession.shared.data(for: request)
  let http = response as? HTTPURLResponse
  return .init(
    status: http?.statusCode ?? 0, body: data,
    retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
}

struct MediaPipelineService: Sendable {
  let runner: any LocalProcessRunning
  let workingDirectory: URL
  let http: MediaPipelineHTTP
  var resolverEnvironment: [String: String] = ProcessInfo.processInfo.environment
  private var fileManager: FileManager { .default }

  func run(_ executable: URL, _ arguments: [String], stage: String, deadline: Date?) async throws
    -> LocalProcessResult {
    do {
      let result = try await runner.run(
        configuration: .init(
          executableURL: executable, arguments: arguments,
          environment: processEnvironment, workingDirectoryURL: workingDirectory,
          stdoutCaptureByteLimit: 2_000_000, stderrCaptureByteLimit: 2_000_000), stdin: "",
        deadline: deadline)
      guard result.terminationStatus == 0 else {
        throw MediaPipelineError.stage(
          stage,
          "process exited with status \(result.terminationStatus): \(redactedStderrTail(result.stderr))"
        )
      }
      return result
    } catch is CancellationError { throw CancellationError() } catch let error as AdapterExecutionError
      where error.code == .timeout { throw error } catch let error as MediaPipelineError { throw error } catch {
      throw MediaPipelineError.stage(stage, "could not run \(executable.lastPathComponent)")
    }
  }

  private func redactedStderrTail(_ stderr: String) -> String {
    MediaPipelineRedaction.diagnostic(String(stderr.suffix(4_000)), environment: resolverEnvironment)
  }

  func executable(_ override: String?, name: String, stage: String) throws -> URL {
    if let override { return URL(fileURLWithPath: override) }
    let paths = resolvedSearchPath.split(separator: ":")
    if let path = paths.map({ URL(fileURLWithPath: String($0)).appendingPathComponent(name) })
      .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
      return path
    }
    let package = name == "yt-dlp" ? "yt-dlp" : "ffmpeg"
    throw MediaPipelineError.stage(
      stage,
      "\(name) is missing; macOS: brew install \(package); Linux: apt-get install \(package) (or use the media add-on image)"
    )
  }

  var resolvedSearchPath: String {
    let resolverPath = resolverEnvironment["PATH"] ?? ""
    let processPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return [resolverPath, processPath, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].filter {
      !$0.isEmpty
    }.joined(separator: ":")
  }

  var processEnvironment: [String: String] {
    var result = ["PATH": resolvedSearchPath]
    for name in ["HOME", "XDG_CACHE_HOME", "DENO_DIR"] {
      if let value = resolverEnvironment[name] { result[name] = value }
    }
    return result
  }

  func ytDlpArguments(_ arguments: [String]) -> [String] {
    let deno = resolvedSearchPath.split(separator: ":").map {
      URL(fileURLWithPath: String($0)).appendingPathComponent("deno")
    }
    .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    return ytDlpArguments(arguments, deno: deno)
  }

  func ytDlpArguments(_ arguments: [String], deno: URL?) -> [String] {
    ["--ignore-config"] + (deno.map { ["--js-runtimes", "deno:\($0.path)"] } ?? []) + arguments
  }

  func ytDlpArguments(_ arguments: [String], cacheDirectory: URL) -> [String] {
    ytDlpArguments(["--cache-dir", cacheDirectory.path] + arguments)
  }

  func missingDownloadOutputMessage(maxFileSizeMB: Int) -> String {
    "yt-dlp did not produce a media file; it may have exceeded the --max-filesize limit of \(maxFileSizeMB)M"
  }
}
