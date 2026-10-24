import CRielaPublicWeb
import Foundation

enum PublicWebError: Error, Equatable, Sendable {
  case invalidInput, blockedDestination, urlPolicy, transport, oversized, timeout, invalidDocument
  case httpStatus(Int)
}

struct PublicWebHTTPRequest: Sendable {
  var url: String
  var host: String
  var headers: [String: String]
  var maximumBytes: Int
  var timeoutMs: Int
}

struct PublicWebHTTPResponse: Sendable {
  var status: Int
  var headers: [String: String]
  var body: Data
  var url: String
}

typealias PublicWebTransport = @Sendable (PublicWebHTTPRequest) async throws -> PublicWebHTTPResponse

final class PublicWebCancellation: @unchecked Sendable {
  let value: OpaquePointer
  init() throws {
    guard let value = riela_web_cancel_create() else { throw PublicWebError.transport }
    self.value = value
  }
  deinit { riela_web_cancel_free(value) }
  func cancel() { riela_web_cancel_set(value) }
}

enum PublicWebHTTP {
  static func native(_ request: PublicWebHTTPRequest) async throws -> PublicWebHTTPResponse {
    let cancellation = try PublicWebCancellation()
    let task = Task.detached(priority: .utility) {
      let headers = request.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
      var response = request.url.withCString { url in request.host.withCString { host in headers.withCString { headers in
        riela_web_fetch(url, host, headers, request.maximumBytes, request.timeoutMs, cancellation.value)
      } } }
      defer { riela_web_response_free(&response) }
      switch response.error {
      case 0: break
      case 2: throw PublicWebError.blockedDestination
      case 4: throw PublicWebError.oversized
      case 5: throw CancellationError()
      case 6: throw PublicWebError.timeout
      default: throw PublicWebError.transport
      }
      let body = response.body.map { Data(bytes: $0, count: response.body_length) } ?? Data()
      let rawHeaders = response.headers.flatMap {
        String(bytes: UnsafeBufferPointer(start: $0, count: response.headers_length).map(UInt8.init(bitPattern:)), encoding: .isoLatin1)
      } ?? ""
      return PublicWebHTTPResponse(status: Int(response.status), headers: parseHeaders(rawHeaders), body: body, url: request.url)
    }
    return try await withTaskCancellationHandler {
      let result = try await task.value
      try Task.checkCancellation()
      return result
    } onCancel: { cancellation.cancel() }
  }

  static func read(
    _ url: String, headers: [String: String] = [:], blockedHosts: [String] = [],
    maximumBytes: Int = 2_000_000, timeoutMs: Int = 25_000, deadline: Date? = nil,
    allowedURLPattern: String? = nil,
    transport: @escaping PublicWebTransport = native
  ) async throws -> PublicWebHTTPResponse {
    guard (1...8_000_000).contains(maximumBytes), (1...120_000).contains(timeoutMs), headers.count <= 2,
      headers.allSatisfy({ ["if-none-match", "if-modified-since"].contains($0.key.lowercased()) &&
        !$0.value.isEmpty && $0.value.utf8.count <= 1024 && !$0.value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }) else {
      throw PublicWebError.invalidInput
    }
    let pattern = try urlPattern(allowedURLPattern)
    func checkURL(_ value: String) throws {
      guard value.utf8.count <= 4096 else { throw PublicWebError.invalidInput }
      if let pattern {
        let range = NSRange(value.startIndex..., in: value)
        guard pattern.firstMatch(in: value, range: range)?.range == range else { throw PublicWebError.urlPolicy }
      }
    }
    let deadline = min(deadline ?? .distantFuture, Date().addingTimeInterval(Double(timeoutMs) / 1000))
    var current = url
    for hop in 0...3 {
      try Task.checkCancellation()
      try checkURL(current)
      let destination = try destination(current, blockedHosts: blockedHosts)
      try checkURL(destination.url)
      let remaining = Int(max(0, deadline.timeIntervalSinceNow * 1000))
      guard remaining > 0 else { throw PublicWebError.timeout }
      var response = try await transport(.init(url: destination.url, host: destination.host,
        headers: headers, maximumBytes: maximumBytes, timeoutMs: remaining))
      guard response.body.count <= maximumBytes else { throw PublicWebError.oversized }
      response.url = destination.url
      response.headers = Dictionary(response.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, next in next })
      if [301, 302, 303, 307, 308].contains(response.status) {
        guard hop < 3, let location = response.headers["location"], location.utf8.count <= 4096,
          let target = URL(string: location, relativeTo: URL(string: destination.url))?.absoluteURL else { throw PublicWebError.invalidInput }
        current = target.absoluteString
        continue
      }
      guard response.status == 200 || response.status == 304 else { throw PublicWebError.httpStatus(response.status) }
      if response.status == 304 { response.body = Data() }
      return response
    }
    throw PublicWebError.invalidInput
  }

  static func urlPattern(_ value: String?) throws -> NSRegularExpression? {
    try value.map { pattern in
      guard !pattern.isEmpty, pattern.utf8.count <= 1024,
        let expression = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z") else { throw PublicWebError.invalidInput }
      return expression
    }
  }

  static func destination(_ text: String, blockedHosts: [String]) throws -> (url: String, host: String) {
    guard text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      var components = URLComponents(string: text), components.scheme?.lowercased() == "https",
      components.user == nil, components.password == nil, components.port == nil || components.port == 443,
      let host = components.url?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]")),
      !host.isEmpty, host.utf8.count <= 253, host.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-.:".unicodeScalars.contains($0)) }),
      blockedHosts.count <= 20 else { throw PublicWebError.invalidInput }
    for blocked in blockedHosts {
      guard blocked.utf8.count <= 253, blocked.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil,
        let name = URL(string: "https://" + blocked)?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { throw PublicWebError.invalidInput }
      if host == name || host.hasSuffix("." + name) { throw PublicWebError.blockedDestination }
    }
    // Numeric literals are checked even for injected transports. Native DNS
    // checks every answer again before any connection, then pins the chosen IP.
    if host.contains(":") || host.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil {
      guard host.withCString({ riela_web_public_ip($0) }) == 1 else { throw PublicWebError.blockedDestination }
    }
    components.scheme = "https"; components.host = host.contains(":") ? "[\(host)]" : host
    components.port = nil; components.fragment = nil
    guard let url = components.url?.absoluteString else { throw PublicWebError.invalidInput }
    return (url, host)
  }

  private static func parseHeaders(_ value: String) -> [String: String] {
    var headers: [String: String] = [:]
    for line in value.components(separatedBy: "\r\n") {
      if line.hasPrefix("HTTP/") { headers = [:]; continue }
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].lowercased()
      headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return headers
  }
}
