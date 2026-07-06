import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol OfficialSDKMiddleware: Sendable {
  func intercept(request: URLRequest) -> URLRequest
  func intercept(response: HTTPURLResponse, data: Data) -> Data
  func interceptStreamChunk(_ chunk: Data) -> Data
}

public extension OfficialSDKMiddleware {
  func intercept(request: URLRequest) -> URLRequest {
    request
  }

  func intercept(response: HTTPURLResponse, data: Data) -> Data {
    data
  }

  func interceptStreamChunk(_ chunk: Data) -> Data {
    chunk
  }
}

public struct OfficialSDKLoggingMiddleware: OfficialSDKMiddleware {
  public typealias Sink = @Sendable (String) -> Void

  public var additionalSensitiveValues: [String]
  private let sink: Sink

  public init(
    additionalSensitiveValues: [String] = [],
    sink: @escaping Sink = OfficialSDKLoggingMiddleware.standardErrorSink
  ) {
    self.additionalSensitiveValues = additionalSensitiveValues
    self.sink = sink
  }

  public func intercept(request: URLRequest) -> URLRequest {
    let method = request.httpMethod ?? "GET"
    let url = request.url?.absoluteString ?? "<unknown-url>"
    let headers = redactedHeaderFields(request.allHTTPHeaderFields ?? [:])
    let body = request.httpBody.flatMap(utf8Text) ?? ""
    log("request \(method) \(url) headers=\(headers) body=\(body)")
    return request
  }

  public func intercept(response: HTTPURLResponse, data: Data) -> Data {
    let body = utf8Text(data) ?? ""
    log("response status=\(response.statusCode) headers=\(redactedHeaderFields(response.allHeaderFields)) body=\(body)")
    return data
  }

  public func interceptStreamChunk(_ chunk: Data) -> Data {
    let body = utf8Text(chunk) ?? "<\(chunk.count) bytes>"
    log("stream chunk bytes=\(chunk.count) body=\(body)")
    return chunk
  }

  private func log(_ message: String) {
    sink(redactAdapterSensitiveText(message, additionalSensitiveValues: additionalSensitiveValues))
  }

  private func redactedHeaderFields(_ fields: [String: String]) -> [String: String] {
    fields.reduce(into: [:]) { result, element in
      result[element.key] = redactedHeaderValue(element.value, headerName: element.key)
    }
  }

  private func redactedHeaderFields(_ fields: [AnyHashable: Any]) -> [String: String] {
    fields.reduce(into: [:]) { result, element in
      let key = String(describing: element.key)
      let value = String(describing: element.value)
      result[key] = redactedHeaderValue(value, headerName: key)
    }
  }

  private func redactedHeaderValue(_ value: String, headerName: String) -> String {
    if isSensitiveHeaderName(headerName) {
      return "<redacted>"
    }
    return redactAdapterSensitiveText(value, additionalSensitiveValues: additionalSensitiveValues)
  }

  private func isSensitiveHeaderName(_ name: String) -> Bool {
    let normalized = name.lowercased()
    return [
      "authorization",
      "api-key",
      "apikey",
      "token",
      "secret",
      "password",
      "passwd",
      "credential",
      "cookie",
      "set-cookie"
    ].contains { normalized.contains($0) }
  }

  private func utf8Text(_ data: Data) -> String? {
    String(data: data, encoding: .utf8)
  }

  public static func standardErrorSink(_ message: String) {
    FileHandle.standardError.write(Data("riela official-sdk \(message)\n".utf8))
  }
}
