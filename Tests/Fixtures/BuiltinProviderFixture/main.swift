// A bounded, loopback-only HTTP fixture compiled solely into the test image.
import Foundation
import Glibc

enum FixtureError: Error { case socket, bind, listen, request, response }

func readRequest(_ client: Int32) throws -> (route: String, body: Data) {
  var bytes = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while bytes.count < 1_048_576 {
    var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 5000) > 0 else { throw FixtureError.request }
    let count = recv(client, &buffer, buffer.count, 0)
    guard count > 0 else { throw FixtureError.request }
    bytes.append(contentsOf: buffer.prefix(count))
    guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)),
          let headers = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { continue }
    let lines = headers.components(separatedBy: "\r\n")
    let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
    guard length >= 0, length <= 1_048_576 else { throw FixtureError.request }
    if bytes.count < boundary.upperBound + length { continue }
    let fields = (lines.first ?? "").split(separator: " ")
    guard fields.count == 3 else { throw FixtureError.request }
    return (fields[0] + " " + fields[1].split(separator: "?")[0],
      Data(bytes[boundary.upperBound..<(boundary.upperBound + length)]))
  }
  throw FixtureError.request
}

func responseBody(for route: String, requestBody: Data) -> (type: String, body: String) {
  if route == "POST /graphql" {
    let document = (try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any])?["query"] as? String
    if document?.contains("KaibaClientReadiness") == true {
      return ("application/json", #"{"data":{"kaibaReadiness":{"result":{"accepted":true,"status":"ok"}}}}"#)
    }
    return ("application/json", #"{"data":{"fixture":"guest-kaiba"}}"#)
  }
  if route == "POST /v1/agents" {
    return ("application/json", #"{"id":"fixture-agent","result":"container-fixture"}"#)
  }
  if route.hasPrefix("GET ") {
    return ("application/json", #"{"data":[{"id":"fixture-model"}],"models":[{"name":"models/fixture-model"}]}"#)
  }
  let event: String
  if route == "POST /v1/responses" {
    event = #"{"type":"response.output_text.delta","delta":"container-fixture"}"#
  } else if route == "POST /v1/messages" {
    event = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"container-fixture"}}"#
  } else if route == "POST /v1/models/fixture-model:streamGenerateContent" {
    event = #"{"candidates":[{"content":{"parts":[{"text":"container-fixture"}]}}]}"#
  } else {
    return ("application/json", #"{"error":"unexpected fixture route"}"#)
  }
  return ("text/event-stream", "data: \(event)\n\n")
}

func serve(_ client: Int32) throws {
  let request = try readRequest(client)
  if let path = ProcessInfo.processInfo.environment["RIELA_TEST_PROVIDER_RECEIPT"] {
    let file = fopen(path, "a")
    guard let file else { throw FixtureError.response }
    defer { fclose(file) }
    fputs(request.route + "\n", file)
  }
  let result = responseBody(for: request.route, requestBody: request.body)
  let response = Data(("HTTP/1.1 200 OK\r\nContent-Type: \(result.type)\r\n"
    + "Content-Length: \(result.body.utf8.count)\r\nConnection: close\r\n\r\n" + result.body).utf8)
  try response.withUnsafeBytes { bytes in
    guard let base = bytes.baseAddress else { throw FixtureError.response }
    var offset = 0
    while offset < bytes.count {
      let count = send(client, base.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
      guard count > 0 else { throw FixtureError.response }
      offset += count
    }
  }
}

let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
guard listener >= 0 else { throw FixtureError.socket }
defer { close(listener) }
var address = sockaddr_in()
address.sin_family = sa_family_t(AF_INET)
address.sin_port = UInt16(31_821).bigEndian
address.sin_addr.s_addr = inet_addr("127.0.0.1")
let bound = withUnsafePointer(to: &address) { pointer in
  pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    Glibc.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
  }
}
guard bound == 0 else { throw FixtureError.bind }
guard listen(listener, 8) == 0 else { throw FixtureError.listen }
try Data().write(to: URL(fileURLWithPath: "/tmp/provider-fixture-ready"))
for _ in 0..<64 {
  let client = accept(listener, nil, nil)
  guard client >= 0 else { break }
  do { try serve(client) } catch { /* A failed request must not expose fixture process state. */ }
  close(client)
}
