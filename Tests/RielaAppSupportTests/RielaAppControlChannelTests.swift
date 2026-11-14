#if os(macOS)
import Darwin
import Foundation
import XCTest
import RielaCore
@testable import RielaAppSupport

final class RielaAppControlChannelTests: XCTestCase {
  private func root() -> URL {
    URL(fileURLWithPath: "/tmp/rac-\(UUID().uuidString.prefix(8))", isDirectory: true)
  }

  func testRoundTripPermissionsAndBodyFreeLogs() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let events = ChannelTestEvents()
    let server = RielaAppControlChannelServer(run: run, handler: { operation, profile in
      events.record(operation, profile: profile)
      return .init(status: 200, body: .object(["value": .string("SECRET_VALUE")]))
    }, log: { events.log($0) })
    try server.bind(socketURL: run.socketURL)
    defer { server.stop() }
    var info = stat()
    XCTAssertEqual(lstat(run.directoryURL.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)
    XCTAssertEqual(lstat(run.socketURL.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    let result = try await RielaAppControlChannelClient(socketURL: run.socketURL).send(.bootstrap, profile: "default")
    XCTAssertEqual(result.status, 200)
    XCTAssertEqual(result.body, .object(["value": .string("SECRET_VALUE")]))
    XCTAssertEqual(events.operations, [.bootstrap])
    XCTAssertEqual(events.profiles, ["default"])
    XCTAssertFalse(events.logs.joined().contains("SECRET_VALUE"))
  }

  func testIdempotencyReplayConflictAndReadOnly() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let events = ChannelTestEvents()
    let server = RielaAppControlChannelServer(run: run, handler: { operation, profile in
      events.record(operation, profile: profile)
      return .init(status: 200, body: .object(["ok": .bool(true)]))
    })
    try server.bind(socketURL: run.socketURL)
    defer { server.stop() }
    let client = RielaAppControlChannelClient(socketURL: run.socketURL, makeRequestId: {
      "00000000-0000-0000-0000-000000000001"
    })
    let request = RielaAppControlOperation.reload(identity: "one", body: Data("{}".utf8))
    let first = try await client.send(request, profile: "default")
    let second = try await client.send(request, profile: "default")
    XCTAssertEqual(first, second)
    XCTAssertEqual(events.operations.count, 1)
    let conflict = try await client.send(.reload(identity: "two", body: Data("{}".utf8)), profile: "default")
    XCTAssertEqual(conflict.status, 409)
    XCTAssertEqual(conflict.body, RielaAppControlResult.error(status: 409, code: "request_id_conflict").body)
    XCTAssertEqual(events.operations.count, 1)
    let readClient = RielaAppControlChannelClient(socketURL: run.socketURL, makeRequestId: {
      "00000000-0000-0000-0000-000000000002"
    })
    _ = try await readClient.send(.environmentStatus(identity: "one"), profile: "default")
    _ = try await readClient.send(.environmentStatus(identity: "one"), profile: "default")
    XCTAssertEqual(events.operations.count, 3)
  }

  func testCacheExpiry() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let events = ChannelTestEvents()
    let server = RielaAppControlChannelServer(run: run, handler: { operation, profile in
      events.record(operation, profile: profile)
      return .init(status: 200, body: .null)
    }, now: { events.now })
    try server.bind(socketURL: run.socketURL)
    defer { server.stop() }
    let client = RielaAppControlChannelClient(socketURL: run.socketURL, makeRequestId: {
      "00000000-0000-0000-0000-000000000003"
    })
    let request = RielaAppControlOperation.reload(identity: "one", body: Data("{}".utf8))
    _ = try await client.send(request, profile: "default")
    events.advance(seconds: 601)
    _ = try await client.send(request, profile: "default")
    XCTAssertEqual(events.operations.count, 2)
  }

  func testProbeFreeLockAndBusyLock() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let first = try RielaAppLocalControlProbe.resolve(appRoot: base)
    guard case let .notRunning(lock) = first else { return XCTFail("expected lock") }
    defer { lock.release() }
    XCTAssertThrowsError(try RielaAppLocalControlProbe.resolve(appRoot: base)) {
      XCTAssertEqual($0 as? RielaAppControlChannelError, .code(.appChannelUnavailable))
    }
  }

  func testProbeLiveSocketAndInsecureSocket() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let server = RielaAppControlChannelServer(run: run, handler: { _, _ in .init(status: 200, body: .null) })
    try server.bind(socketURL: run.socketURL)
    defer { server.stop() }
    guard case .channel = try RielaAppLocalControlProbe.resolve(appRoot: base) else {
      return XCTFail("expected channel")
    }
    XCTAssertEqual(chmod(run.socketURL.path, 0o666), 0)
    do {
      _ = try await RielaAppControlChannelClient(socketURL: run.socketURL).send(.bootstrap, profile: "default")
      XCTFail("expected insecure socket error")
    } catch {
      XCTAssertEqual(error as? RielaAppControlChannelError, .code(.appChannelInsecure))
    }
  }

  func testRawOversizedMalformedAndDeadline() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let events = ChannelTestEvents()
    let server = RielaAppControlChannelServer(run: run, handler: { operation, profile in
      events.record(operation, profile: profile)
      return .init(status: 200, body: .null)
    }, readDeadlineSeconds: 0.2)
    try server.bind(socketURL: run.socketURL)
    defer { server.stop() }
    let oversized = try rawConnection(run.socketURL)
    defer { close(oversized) }
    try rawWrite(oversized, bytes: [0, 9, 0, 1])
    let response = try rawResponse(oversized)
    XCTAssertEqual(response.status, 413)
    XCTAssertEqual(response.body, RielaAppControlResult.error(status: 413, code: "request_too_large").body)
    let malformed = try rawConnection(run.socketURL)
    defer { close(malformed) }
    let body = Array("{\"extra\":true}".utf8)
    try rawWrite(malformed, bytes: [0, 0, 0, UInt8(body.count)] + body)
    XCTAssertEqual(try rawResponse(malformed).status, 400)
    let extra = try rawConnection(run.socketURL)
    defer { close(extra) }
    let valid = try RielaAppControlRequestEnvelope(requestId: "00000000-0000-0000-0000-000000000001", operation: .bootstrap, profile: "default").encoded()
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    object["extra"] = true
    let extraBody = try JSONSerialization.data(withJSONObject: object)
    try rawFrame(extra, data: extraBody)
    XCTAssertEqual(try rawResponse(extra).status, 400)
    let stalled = try rawConnection(run.socketURL)
    defer { close(stalled) }
    try rawWrite(stalled, bytes: [0, 0])
    var descriptor = pollfd(fd: stalled, events: Int16(POLLIN), revents: 0)
    XCTAssertGreaterThan(poll(&descriptor, 1, 2_000), 0)
    var byte: UInt8 = 0
    XCTAssertEqual(read(stalled, &byte, 1), 0)
    XCTAssertTrue(events.operations.isEmpty)
  }

  func testProbePreservesStaleSocket() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let server = RielaAppControlChannelServer(run: run, handler: { _, _ in .init(status: 200, body: .null) })
    try server.bind(socketURL: run.socketURL)
    server.stop()
    guard case let .notRunning(lock) = try RielaAppLocalControlProbe.resolve(appRoot: base) else {
      return XCTFail("expected lock for stale socket")
    }
    defer { lock.release() }
    XCTAssertTrue(FileManager.default.fileExists(atPath: run.socketURL.path))
  }

  func testConcurrentDeduplicationAndCapacity() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let gate = ChannelTestGate()
    let server = RielaAppControlChannelServer(run: run, handler: { _, _ in
      await gate.wait()
      return .init(status: 200, body: .null)
    }, idempotencyCapacity: 2)
    try server.bind(socketURL: run.socketURL)
    defer { server.stop() }
    func client(_ id: String) -> RielaAppControlChannelClient {
      RielaAppControlChannelClient(socketURL: run.socketURL, makeRequestId: { id })
    }
    let request = RielaAppControlOperation.reload(identity: "one", body: Data("{}".utf8))
    let firstClient = client("00000000-0000-0000-0000-000000000011")
    let first = Task { try await firstClient.send(request, profile: "default") }
    for _ in 0..<200 {
      if await gate.count >= 1 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let duplicate = Task { try await firstClient.send(request, profile: "default") }
    let secondClient = client("00000000-0000-0000-0000-000000000012")
    let second = Task { try await secondClient.send(request, profile: "default") }
    for _ in 0..<200 {
      if await gate.count >= 2 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let busy = try await client("00000000-0000-0000-0000-000000000013").send(request, profile: "default")
    XCTAssertEqual(busy.status, 503)
    XCTAssertEqual(busy.body, RielaAppControlResult.error(status: 503, code: "channel_busy").body)
    await gate.release()
    let firstResult = try await first.value
    let duplicateResult = try await duplicate.value
    _ = try await second.value
    XCTAssertEqual(firstResult, duplicateResult)
    let count = await gate.count
    XCTAssertEqual(count, 2)
  }

  func testRetryAfterCloseUsesSameRequestID() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let listener = try rawListener(run.socketURL)
    defer { close(listener) }
    let server = Task.detached { () throws -> [String] in
      var ids: [String] = []
      for index in 0..<2 {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
          let request = try RielaAppControlRequestEnvelope.decodeStrict(rawReadFrame(fd))
          ids.append(request.requestId)
          if index == 1 {
            let response = RielaAppControlResponseEnvelope(requestId: request.requestId, status: 200, body: .null)
            try rawFrame(fd, data: JSONEncoder().encode(response))
          }
          close(fd)
        } catch {
          close(fd)
          throw error
        }
      }
      return ids
    }
    let expected = "00000000-0000-0000-0000-000000000020"
    let client = RielaAppControlChannelClient(socketURL: run.socketURL, makeRequestId: { expected })
    let result = try await client.send(.bootstrap, profile: "default")
    let ids = try await server.value
    XCTAssertEqual(result.status, 200)
    XCTAssertEqual(ids, [expected, expected])
  }

  func testPathLength() async throws {
    let path = "/tmp/" + String(repeating: "x", count: 99)
    let socket = URL(fileURLWithPath: path)
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let server = RielaAppControlChannelServer(run: run, handler: { _, _ in .init(status: 200, body: .null) })
    XCTAssertThrowsError(try server.bind(socketURL: socket))
    do {
      _ = try await RielaAppControlChannelClient(socketURL: socket).send(.bootstrap, profile: "default")
      XCTFail("expected long path error")
    } catch {
      XCTAssertEqual(error as? RielaAppControlChannelError, .code(.appChannelPathTooLong))
    }
  }
}

private actor ChannelTestGate {
  private(set) var count = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    count += 1
    await withCheckedContinuation { continuations.append($0) }
  }
  func release() { continuations.forEach { $0.resume() }; continuations.removeAll() }
}

private func rawConnection(_ url: URL) throws -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw POSIXError(.EIO) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let bytes = Array(url.path.utf8CString)
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
  }
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
  return fd
}

private func rawListener(_ url: URL) throws -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw POSIXError(.EIO) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let bytes = Array(url.path.utf8CString)
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
  }
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard result == 0, chmod(url.path, 0o600) == 0, listen(fd, 2) == 0 else {
    close(fd)
    throw POSIXError(.EIO)
  }
  return fd
}

private func rawFrame(_ fd: Int32, data: Data) throws {
  let length = UInt32(data.count)
  let header = [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
                UInt8((length >> 8) & 255), UInt8(length & 255)]
  try rawWrite(fd, bytes: header + Array(data))
}

private func rawReadFrame(_ fd: Int32) throws -> Data {
  func readExactly(_ length: Int) throws -> Data {
    var data = Data(count: length)
    var offset = 0
    while offset < length {
      let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), length - offset) }
      guard count > 0 else { throw POSIXError(.EIO) }
      offset += count
    }
    return data
  }
  let header = try readExactly(4)
  let length = header.reduce(0) { ($0 << 8) | Int($1) }
  guard length <= RielaAppControlLimits.maxResponseFrameBytes else { throw POSIXError(.EFBIG) }
  return try readExactly(length)
}

private func rawWrite(_ fd: Int32, bytes: [UInt8]) throws {
  var offset = 0
  while offset < bytes.count {
    let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
    guard count > 0 else { throw POSIXError(.EIO) }
    offset += count
  }
}

private func rawResponse(_ fd: Int32) throws -> RielaAppControlResponseEnvelope {
  func readExactly(_ length: Int) throws -> Data {
    var data = Data(count: length)
    var offset = 0
    while offset < length {
      let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), length - offset) }
      guard count > 0 else { throw POSIXError(.EIO) }
      offset += count
    }
    return data
  }
  let header = try readExactly(4)
  let length = header.reduce(0) { ($0 << 8) | Int($1) }
  guard length <= RielaAppControlLimits.maxResponseFrameBytes else { throw POSIXError(.EFBIG) }
  return try RielaAppControlResponseEnvelope.decodeStrict(readExactly(length))
}

private final class ChannelTestEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedOperations: [RielaAppControlOperation] = []
  private var recordedProfiles: [String] = []
  private var recordedLogs: [String] = []
  private var clock = Date(timeIntervalSince1970: 1_000)
  var operations: [RielaAppControlOperation] { lock.lock(); defer { lock.unlock() }; return recordedOperations }
  var profiles: [String] { lock.lock(); defer { lock.unlock() }; return recordedProfiles }
  var logs: [String] { lock.lock(); defer { lock.unlock() }; return recordedLogs }
  var now: Date { lock.lock(); defer { lock.unlock() }; return clock }
  func record(_ operation: RielaAppControlOperation, profile: String) {
    lock.lock(); defer { lock.unlock() }
    recordedOperations.append(operation)
    recordedProfiles.append(profile)
  }
  func log(_ message: String) { lock.lock(); defer { lock.unlock() }; recordedLogs.append(message) }
  func advance(seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; clock.addTimeInterval(seconds) }
}
#endif
