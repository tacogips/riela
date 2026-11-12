#if os(macOS)
import Darwin
import Foundation
import RielaCore

public enum RielaAppControlChannelServerError: Error, Equatable {
  case pathTooLong
  case insecure
  case io(Int32)
}

private actor ControlRequestCache {
  struct Entry {
    let digest: String
    let task: Task<RielaAppControlResult, Never>
    var completed: Date?
  }
  private var entries: [String: Entry] = [:]
  private let capacity: Int
  private let now: @Sendable () -> Date

  init(capacity: Int, now: @escaping @Sendable () -> Date) {
    self.capacity = capacity
    self.now = now
  }

  func execute(_ request: RielaAppControlRequestEnvelope,
               handler: @escaping RielaAppControlChannelServer.Handler) async -> RielaAppControlResult {
    guard !request.operation.isReadOnly else { return await handler(request.operation, request.profile) }
    guard let digest = try? request.digest() else { return .error(status: 400, code: "invalid_request") }
    let time = now()
    entries = entries.filter { _, entry in
      guard let completed = entry.completed else { return true }
      return time.timeIntervalSince(completed) < Double(RielaAppControlLimits.idempotencyTTLSeconds)
    }
    if let entry = entries[request.requestId] {
      guard entry.digest == digest else { return .error(status: 409, code: "request_id_conflict") }
      return await entry.task.value
    }
    if entries.count >= capacity {
      if let oldest = entries.filter({ $0.value.completed != nil }).min(by: {
        ($0.value.completed ?? .distantFuture) < ($1.value.completed ?? .distantFuture)
      })?.key {
        entries.removeValue(forKey: oldest)
      } else {
        return .error(status: 503, code: "channel_busy")
      }
    }
    let task = Task { await handler(request.operation, request.profile) }
    entries[request.requestId] = Entry(digest: digest, task: task, completed: nil)
    let result = await task.value
    if var entry = entries[request.requestId], entry.digest == digest {
      entry.completed = now()
      entries[request.requestId] = entry
    }
    return result
  }
}

public final class RielaAppControlChannelServer: @unchecked Sendable {
  public typealias Handler = @Sendable (RielaAppControlOperation, _ profile: String) async -> RielaAppControlResult
  private let run: RielaAppRunDirectory
  private let handler: Handler
  private let log: @Sendable (String) -> Void
  private let readDeadlineSeconds: Double
  private let cache: ControlRequestCache
  private let lock = NSLock()
  private var listener: Int32 = -1

  public init(run: RielaAppRunDirectory, handler: @escaping Handler,
              log: @escaping @Sendable (String) -> Void = { _ in },
              readDeadlineSeconds: Double = Double(RielaAppControlLimits.requestReadDeadlineSeconds),
              now: @escaping @Sendable () -> Date = Date.init,
              idempotencyCapacity: Int = RielaAppControlLimits.idempotencyCapacity) {
    self.run = run
    self.handler = handler
    self.log = log
    self.readDeadlineSeconds = readDeadlineSeconds
    self.cache = ControlRequestCache(capacity: idempotencyCapacity, now: now)
  }

  public func bind(socketURL: URL) throws {
    let path = socketURL.path
    guard path.utf8.count <= RielaAppControlLimits.maxSocketPathBytes else {
      throw RielaAppControlChannelServerError.pathTooLong
    }
    guard socketURL.standardizedFileURL == run.socketURL.standardizedFileURL else {
      throw RielaAppControlChannelServerError.insecure
    }
    do { try run.validate() } catch { throw RielaAppControlChannelServerError.insecure }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RielaAppControlChannelServerError.io(errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { dest in
      _ = path.utf8CString.withUnsafeBytes { dest.copyBytes(from: $0) }
    }
    let previousMask = umask(0o177)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    let bindError = errno
    _ = umask(previousMask)
    guard result == 0 else { close(fd); throw RielaAppControlChannelServerError.io(bindError) }
    guard chmod(path, 0o600) == 0 else { let code = errno; close(fd); throw RielaAppControlChannelServerError.io(code) }
    do { try run.validate(); try run.validateSocketFile() } catch {
      close(fd); throw RielaAppControlChannelServerError.insecure
    }
    guard listen(fd, 16) == 0 else { let code = errno; close(fd); throw RielaAppControlChannelServerError.io(code) }
    lock.lock(); listener = fd; lock.unlock()
    Thread { [weak self] in self?.acceptLoop(fd) }.start()
  }

  public func stop() {
    lock.lock(); let fd = listener; listener = -1; lock.unlock()
    if fd >= 0 { _ = shutdown(fd, SHUT_RDWR); close(fd) }
  }

  private func acceptLoop(_ fd: Int32) {
    while true {
      let connection = accept(fd, nil, nil)
      if connection < 0 {
        if errno == EINTR { continue }
        return
      }
      Task { await self.handle(connection) }
    }
  }

  private func handle(_ fd: Int32) async {
    defer { close(fd) }
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return }
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let deadline = Date().addingTimeInterval(readDeadlineSeconds)
    guard let header = readExactly(fd, count: 4, deadline: deadline) else { return }
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    if length > RielaAppControlLimits.maxRequestFrameBytes {
      send(fd, id: "", result: .error(status: 413, code: "request_too_large")); return
    }
    guard let data = readExactly(fd, count: length, deadline: deadline) else { return }
    guard let request = try? RielaAppControlRequestEnvelope.decodeStrict(data) else {
      send(fd, id: "", result: .error(status: 400, code: "invalid_request")); return
    }
    let result = await cache.execute(request, handler: handler)
    send(fd, id: request.requestId, result: result)
    var code = "-"
    if case let .object(body) = result.body, case let .object(error) = body["error"],
       case let .string(value) = error["code"], ["request_too_large", "invalid_request", "request_id_conflict", "channel_busy",
        "app_channel_protocol_error"].contains(value) {
      code = value
    }
    log("operation=\(request.operation.wireName) request=\(request.requestId.prefix(8)) status=\(result.status) code=\(code)")
  }

  private func readExactly(_ fd: Int32, count: Int, deadline: Date) -> Data? {
    var result = Data(count: count)
    var offset = 0
    while offset < count {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { return nil }
      var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&event, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
      if ready < 0 && errno == EINTR { continue }
      guard ready > 0 else { return nil }
      let received = result.withUnsafeMutableBytes { bytes in Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset) }
      if received < 0 && errno == EINTR { continue }
      guard received > 0 else { return nil }
      offset += received
    }
    return result
  }

  private func send(_ fd: Int32, id: String, result: RielaAppControlResult) {
    func encode(_ result: RielaAppControlResult) -> Data? {
      try? JSONEncoder().encode(RielaAppControlResponseEnvelope(requestId: id, status: result.status, body: result.body))
    }
    guard var data = encode(result) else { return }
    if data.count > RielaAppControlLimits.maxResponseFrameBytes {
      guard let fallback = encode(.error(status: 500, code: "app_channel_protocol_error")) else { return }
      data = fallback
    }
    var length = UInt32(data.count).bigEndian
    let header = withUnsafeBytes(of: &length) { Data($0) }
    for part in [header, data] {
      var offset = 0
      while offset < part.count {
        let sent = part.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), part.count - offset) }
        if sent < 0 && errno == EINTR { continue }
        guard sent > 0 else { return }
        offset += sent
      }
    }
  }
}
#endif
