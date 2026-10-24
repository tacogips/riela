import Foundation
import RielaAdapters
import RielaCore

typealias PublicWebBrowser = @Sendable (String, PublicWebPageOptions, [String], Date?) async throws -> PublicWebPage

enum PublicWebExecutionContext {
  @TaskLocal static var transport: PublicWebTransport?
  @TaskLocal static var browser: PublicWebBrowser?
}

struct PublicWebReader: Sendable {
  var transport: PublicWebTransport = PublicWebHTTP.native
  var browser: PublicWebBrowser

  func page(
    url: String, options: PublicWebPageOptions, blockedHosts: [String], metadataOnly: Bool,
    includeRaw: Bool, linkPattern: String?, deadline: Date?
  ) async throws -> JSONObject {
    _ = try PublicWebHTTP.destination(url, blockedHosts: blockedHosts)
    let deadline = min(deadline ?? .distantFuture, Date().addingTimeInterval(Double(options.timeoutMs) / 1000))
    var keepLink: ((String) -> Bool)?
    if let pattern = linkPattern {
      guard pattern.utf8.count <= 512, let regex = try? NSRegularExpression(pattern: pattern) else { throw PublicWebError.invalidInput }
      keepLink = { href in
        guard let target = URL(string: href, relativeTo: URL(string: url))?.absoluteURL,
          target.host == URL(string: url)?.host, target.absoluteString.utf8.count <= 4096 else { return false }
        return regex.firstMatch(in: target.path, range: NSRange(target.path.startIndex..., in: target.path)) != nil
      }
    }
    if options.mode != "browser" || metadataOnly {
      do {
        let response = try await PublicWebHTTP.read(url, blockedHosts: blockedHosts, timeoutMs: options.timeoutMs, deadline: deadline, transport: transport)
        guard response.status == 200 else { throw PublicWebError.httpStatus(response.status) }
        let page = try PublicWebDocument.parse(response.body, url: response.url, options: options, metadataOnly: metadataOnly, keepLink: keepLink)
        if metadataOnly || options.mode == "http" || page.text.unicodeScalars.count >= options.minimumTextCharacters {
          var result = page.payload()
          if includeRaw { result["raw_body_base64"] = .string(response.body.base64EncodedString()) }
          return result
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as PublicWebError where error == .blockedDestination || error == .invalidInput {
        throw error
      } catch {
        if metadataOnly || options.mode == "http" { throw error }
      }
    }
    guard !includeRaw else { throw PublicWebError.invalidInput }
    return try await browser(url, options, blockedHosts, deadline).payload()
  }
}

extension BuiltinWorkflowAddonResolver {
  func publicWebBrowser(url: String, options: PublicWebPageOptions, blockedHosts: [String], deadline: Date?) async throws -> PublicWebPage {
    let candidates = environment["RIELA_PUBLIC_WEB_PYTHON"].map { [$0] } ?? ["/usr/local/bin/python3", "/usr/bin/python3"]
    guard let python = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }),
      let script = PublicWebResources.browserScript() else { throw PublicWebError.transport }
    let value: JSONObject = ["url": .string(url), "blocked_hosts": .array(blockedHosts.map(JSONValue.string)),
      "options": .object(["timeout_ms": .integer(Int64(options.timeoutMs)), "wait_ms": .integer(Int64(options.waitMs))])]
    let configuration = LocalProcessConfiguration(executableURL: URL(fileURLWithPath: python), arguments: ["-I", "-B", script.path],
      environment: ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/tmp", "TMPDIR": "/tmp", "PLAYWRIGHT_BROWSERS_PATH": "/opt/playwright"],
      inheritEnvironment: false, stdoutCaptureByteLimit: 2_000_001)
    let result = try await containerProcessRunner.run(configuration: configuration,
      stdin: try JSONValue.object(value).compactJSONString(),
      deadline: min(deadline ?? .distantFuture, Date().addingTimeInterval(Double(options.timeoutMs) / 1000 + 15)))
    guard result.terminationStatus == 0, !result.stdoutInvalidUTF8,
      (result.stdoutRetainedByteCount ?? result.stdout.utf8.count) <= 2_000_000,
      let raw = result.stdout.data(using: .utf8),
      case let .object(output) = try JSONDecoder().decode(JSONValue.self, from: raw),
      Set(output.keys).isSubset(of: ["url", "title", "text", "links", "published_at"]),
      case let .string(url)? = output["url"], case let .string(title)? = output["title"],
      case let .string(text)? = output["text"], case let .array(links)? = output["links"], links.count <= 200 else { throw PublicWebError.transport }
    let final = try PublicWebHTTP.destination(url, blockedHosts: blockedHosts).url
    let published: String?
    switch output["published_at"] {
    case let .string(value)? where value.unicodeScalars.count <= 80: published = value
    case nil, .null?: published = nil
    default: throw PublicWebError.invalidDocument
    }
    let hrefs = try links.map { value -> String in
      guard case let .string(text) = value, text.utf8.count <= 4096 else { throw PublicWebError.invalidDocument }; return text
    }
    return .init(url: final, title: PublicWebDocument.compact(title, limit: 500),
      text: PublicWebDocument.compact(text, limit: options.maximumTextCharacters),
      links: PublicWebDocument.safeLinks(hrefs, base: final), publishedAt: published, metadataOnly: false, method: "browser")
  }
}
