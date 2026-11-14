import Foundation

public enum RielaHTTPRequestParseResult: Equatable, Sendable {
  case incomplete
  case complete(RielaHTTPRequest)
}

public enum RielaHTTPRequestParserError: LocalizedError, Equatable, Sendable {
  case headersTooLarge
  case bodyTooLarge
  case malformedRequest
  case invalidTarget
  case invalidContentLength
  case unsupportedTransferEncoding

  public var errorDescription: String? {
    switch self {
    case .headersTooLarge: "HTTP headers exceed the 32 KiB limit."
    case .bodyTooLarge: "HTTP body exceeds the 2 MiB limit."
    case .malformedRequest: "Malformed HTTP request."
    case .invalidTarget: "Invalid HTTP request target."
    case .invalidContentLength: "Invalid Content-Length header."
    case .unsupportedTransferEncoding: "Transfer-Encoding is not supported."
    }
  }

  public var status: Int {
    switch self {
    case .headersTooLarge: 431
    case .bodyTooLarge: 413
    default: 400
    }
  }
}

public struct RielaHTTPRequestParser: Sendable {
  public static let maximumHeaderBytes = 32 * 1_024
  public static let maximumBodyBytes = 2 * 1_024 * 1_024

  public init() {}

  public func parse(_ data: Data) throws -> RielaHTTPRequestParseResult {
    let boundary = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: boundary) else {
      if data.count > Self.maximumHeaderBytes {
        throw RielaHTTPRequestParserError.headersTooLarge
      }
      return .incomplete
    }
    guard headerRange.lowerBound <= Self.maximumHeaderBytes else {
      throw RielaHTTPRequestParserError.headersTooLarge
    }
    guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
      throw RielaHTTPRequestParserError.malformedRequest
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw RielaHTTPRequestParserError.malformedRequest
    }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestParts.count == 3,
          requestParts[2] == "HTTP/1.1",
          !requestParts[0].isEmpty else {
      throw RielaHTTPRequestParserError.malformedRequest
    }
    let target = String(requestParts[1])
    let (path, query) = try normalizedTarget(target)
    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let separator = line.firstIndex(of: ":") else {
        throw RielaHTTPRequestParserError.malformedRequest
      }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, headers[name] == nil else {
        throw RielaHTTPRequestParserError.malformedRequest
      }
      headers[name] = value
    }
    if let transferEncoding = headers["transfer-encoding"], !transferEncoding.isEmpty {
      throw RielaHTTPRequestParserError.unsupportedTransferEncoding
    }
    let contentLength: Int
    if let rawLength = headers["content-length"] {
      guard let parsed = Int(rawLength), parsed >= 0 else {
        throw RielaHTTPRequestParserError.invalidContentLength
      }
      contentLength = parsed
    } else {
      contentLength = 0
    }
    guard contentLength <= Self.maximumBodyBytes else {
      throw RielaHTTPRequestParserError.bodyTooLarge
    }
    let bodyStart = headerRange.upperBound
    let availableBodyBytes = data.count - bodyStart
    guard availableBodyBytes >= contentLength else {
      return .incomplete
    }
    guard availableBodyBytes == contentLength else {
      throw RielaHTTPRequestParserError.malformedRequest
    }
    return .complete(RielaHTTPRequest(
      method: String(requestParts[0]),
      path: path,
      query: query,
      headers: headers,
      body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
    ))
  }

  private func normalizedTarget(_ target: String) throws -> (String, String?) {
    guard target.hasPrefix("/"),
          !target.contains("\\"),
          !target.unicodeScalars.contains(where: { $0.value == 0 }) else {
      throw RielaHTTPRequestParserError.invalidTarget
    }
    let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let rawPath = String(pieces[0])
    guard validPercentEncoding(in: rawPath), let decodedPath = rawPath.removingPercentEncoding else {
      throw RielaHTTPRequestParserError.invalidTarget
    }
    let segments = decodedPath.split(separator: "/", omittingEmptySubsequences: false)
    guard !segments.contains(where: { $0 == "." || $0 == ".." }),
          !decodedPath.contains("\\") else {
      throw RielaHTTPRequestParserError.invalidTarget
    }
    return (decodedPath, pieces.count == 2 ? String(pieces[1]) : nil)
  }

  private func validPercentEncoding(in value: String) -> Bool {
    let characters = Array(value)
    var index = 0
    while index < characters.count {
      if characters[index] == "%" {
        guard index + 2 < characters.count,
              characters[index + 1].isHexDigit,
              characters[index + 2].isHexDigit else {
          return false
        }
        index += 3
      } else {
        index += 1
      }
    }
    return true
  }
}
