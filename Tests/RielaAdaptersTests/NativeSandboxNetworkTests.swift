import Foundation
import RielaCore
import XCTest
@testable import RielaAdapters
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class NativeSandboxNetworkTests: XCTestCase {
  func testNetworkPolicyDeniesTCPAndAllowsExplicitEgress() async throws {
    let root = try testDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try await buildClient(root)
    #if os(Linux)
    let type = Int32(SOCK_STREAM.rawValue)
    #else
    let type = SOCK_STREAM
    #endif
    let listener = socket(AF_INET, type, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        #if canImport(Darwin)
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        #else
        Glibc.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        #endif
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertEqual(listen(listener, 4), 0)
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    XCTAssertEqual(withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
    }, 0)
    for allowed in [false, true] {
      let state = root.appendingPathComponent(allowed ? "allowed" : "denied")
      for name in ["home", "tmp"] {
        try FileManager.default.createDirectory(at: state.appendingPathComponent(name), withIntermediateDirectories: true)
      }
      let invocation = try NativeProcessSandbox().invocation(for: .init(executableURL: client,
        arguments: [String(UInt16(bigEndian: address.sin_port))], workingDirectoryURL: root.appendingPathComponent("workspace")),
        options: .init(networkPolicy: allowed ? .egressAllowed : .denied), stateDirectory: state)
      let output = try await FoundationLocalProcessRunner().run(configuration: invocation, stdin: "", deadline: Date().addingTimeInterval(10))
      XCTAssertEqual(output.terminationStatus == 0, allowed, output.stderr)
    }
  }

  private func testDirectory() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/execution-sandbox/net-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
    return root
  }

  private func buildClient(_ root: URL) async throws -> URL {
    let source = root.appendingPathComponent("client.c")
    let output = root.appendingPathComponent("client")
    try """
    #include <arpa/inet.h>
    #include <stdlib.h>
    #include <sys/socket.h>
    #include <unistd.h>
    int main(int argc, char **argv) {
      if (argc != 2) return 2;
      int fd = socket(AF_INET, SOCK_STREAM, 0);
      if (fd < 0) return 3;
      struct sockaddr_in address = {0};
      address.sin_family = AF_INET;
      address.sin_port = htons((unsigned short)atoi(argv[1]));
      address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      int status = connect(fd, (struct sockaddr *)&address, sizeof(address));
      close(fd);
      return status == 0 ? 0 : 4;
    }
    """.write(to: source, atomically: true, encoding: .utf8)
    let result = try await FoundationLocalProcessRunner().run(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/cc"),
      arguments: [source.path, "-o", output.path]), stdin: "", deadline: Date().addingTimeInterval(30))
    XCTAssertEqual(result.terminationStatus, 0, result.stderr)
    return output
  }
}
