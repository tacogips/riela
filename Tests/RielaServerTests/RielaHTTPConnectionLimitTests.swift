import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RielaServer
import XCTest

final class RielaHTTPConnectionLimitTests: XCTestCase {
  func testConnectionQuotaRejectsExcessBeforeRequestParsing() async throws {
    let server = makeServer(maximum: 1, timeout: 1)
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let first = try openSocket(port: port)
    defer { _ = close(first) }
    try await Task.sleep(for: .milliseconds(50))
    let excess = try openSocket(port: port)
    defer { _ = close(excess) }
    let started = ContinuousClock.now
    XCTAssertTrue(isClosed(excess), "An idle connection above the quota must be closed")
    XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
    XCTAssertTrue(isClosed(first), "The admitted idle connection must expire")
    try await assertHealthy(port: port)
  }

  func testPartialBodyDeadlineDoesNotResetWhenBytesArrive() async throws {
    let server = makeServer(maximum: 2, timeout: 0.3)
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let socket = try openSocket(port: port)
    defer { _ = close(socket) }
    let request = "POST /healthz HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\na"
    try FileHandle(fileDescriptor: socket, closeOnDealloc: false).write(contentsOf: Data(request.utf8))
    try await Task.sleep(for: .milliseconds(200))
    try FileHandle(fileDescriptor: socket, closeOnDealloc: false).write(contentsOf: Data("b".utf8))
    let started = ContinuousClock.now
    XCTAssertTrue(isClosed(socket))
    XCTAssertLessThan(started.duration(to: .now), .milliseconds(250))
    try await assertHealthy(port: port)
  }

  private func makeServer(maximum: Int, timeout: TimeInterval) -> RielaLocalHTTPServer {
    RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in .text(status: 200, "healthy") },
      connectionLimits: .init(maximumConnections: maximum, requestReadTimeout: timeout))
  }

  private func assertHealthy(port: Int) async throws {
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/healthz"))
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
  }

  private func openSocket(port: Int) throws -> Int32 {
    #if canImport(Darwin)
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { _ = close(descriptor); throw POSIXError(.ECONNREFUSED) }
    return descriptor
  }

  private func isClosed(_ socket: Int32) -> Bool {
    var byte: UInt8 = 0
    let result = recv(socket, &byte, 1, 0)
    return result == 0 || (result < 0 && errno == ECONNRESET)
  }
}
