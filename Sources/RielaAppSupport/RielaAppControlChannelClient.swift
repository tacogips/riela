#if os(macOS)
import Darwin
import Foundation

public enum RielaAppControlChannelError: Error, Equatable {
  case code(RielaAppControlErrorCode)
}

private enum ChannelIOError: Error {
  case closedBeforeResponse
  case timeout
  case unavailable(Int32)
  case insecure
  case protocolError
}

private enum ChannelSocket {
  static func address(_ url: URL) throws -> sockaddr_un {
    let bytes = Array(url.path.utf8)
    guard bytes.count <= RielaAppControlLimits.maxSocketPathBytes else {
      throw RielaAppControlChannelError.code(.appChannelPathTooLong)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    return address
  }

  static func validate(_ run: RielaAppRunDirectory) throws {
    do {
      try run.validate()
      try run.validateSocketFile()
      var info = stat()
      if lstat(run.socketURL.path, &info) == 0 && info.st_mode & 0o777 != 0o600 {
        throw ChannelIOError.insecure
      }
    } catch let error as RielaAppOwnerLockError {
      if case let .io(code) = error, code == ENOENT { throw ChannelIOError.unavailable(code) }
      throw ChannelIOError.insecure
    }
  }

  static func wait(_ fd: Int32, events: Int16, deadline: Date) throws {
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw ChannelIOError.timeout }
      var item = pollfd(fd: fd, events: events, revents: 0)
      let result = poll(&item, 1, Int32(min(ceil(remaining * 1_000), Double(Int32.max))))
      if result > 0 { return }
      if result == 0 { throw ChannelIOError.timeout }
      if errno != EINTR { throw ChannelIOError.unavailable(errno) }
    }
  }

  static func connect(_ url: URL, timeout: Double) throws -> Int32 {
    var address = try address(url)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ChannelIOError.unavailable(errno) }
    do {
      var noSignal: Int32 = 1
      _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw ChannelIOError.unavailable(errno)
      }
      let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      if result != 0 {
        guard errno == EINPROGRESS else { throw ChannelIOError.unavailable(errno) }
        try wait(fd, events: Int16(POLLOUT), deadline: Date().addingTimeInterval(timeout))
        var code: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0 else {
          throw ChannelIOError.unavailable(errno)
        }
        guard code == 0 else { throw ChannelIOError.unavailable(code) }
      }
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw ChannelIOError.insecure }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }

  static func writeFrame(_ data: Data, fd: Int32, deadline: Date) throws {
    var size = UInt32(data.count).bigEndian
    var frame = withUnsafeBytes(of: &size) { Data($0) }
    frame.append(data)
    var offset = 0
    while offset < frame.count {
      try wait(fd, events: Int16(POLLOUT), deadline: deadline)
      let count = frame.withUnsafeBytes { bytes in
        Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      if count > 0 { offset += count; continue }
      if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      throw ChannelIOError.unavailable(errno)
    }
  }

  static func readExactly(_ count: Int, fd: Int32, deadline: Date, allowRetry: Bool) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      try wait(fd, events: Int16(POLLIN), deadline: deadline)
      let received = data.withUnsafeMutableBytes { bytes in
        Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
      }
      if received > 0 { offset += received; continue }
      if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      if received == 0 && offset == 0 && allowRetry { throw ChannelIOError.closedBeforeResponse }
      throw ChannelIOError.protocolError
    }
    return data
  }
}

public struct RielaAppControlChannelClient: Sendable {
  public let socketURL: URL
  private let connectTimeoutSeconds: Double
  private let responseTimeoutSeconds: Double
  private let makeRequestId: @Sendable () -> String

  public init(socketURL: URL, connectTimeoutSeconds: Double = 2, responseTimeoutSeconds: Double = 30,
              makeRequestId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
    self.socketURL = socketURL
    self.connectTimeoutSeconds = connectTimeoutSeconds
    self.responseTimeoutSeconds = responseTimeoutSeconds
    self.makeRequestId = makeRequestId
  }

  public func send(_ operation: RielaAppControlOperation, profile: String) async throws -> RielaAppControlResult {
    let requestId = makeRequestId()
    do {
      _ = try ChannelSocket.address(socketURL)
      let run = RielaAppRunDirectory(appRoot: socketURL.deletingLastPathComponent().deletingLastPathComponent())
      guard socketURL.standardizedFileURL == run.socketURL.standardizedFileURL else { throw ChannelIOError.insecure }
      let request = try RielaAppControlRequestEnvelope(requestId: requestId, operation: operation, profile: profile).encoded()
      guard request.count <= RielaAppControlLimits.maxRequestFrameBytes else { throw ChannelIOError.protocolError }
      let deadline = Date().addingTimeInterval(responseTimeoutSeconds)
      for attempt in 0...1 {
        do {
          try ChannelSocket.validate(run)
          let fd = try ChannelSocket.connect(socketURL, timeout: connectTimeoutSeconds)
          defer { close(fd) }
          try ChannelSocket.writeFrame(request, fd: fd, deadline: deadline)
          let header = try ChannelSocket.readExactly(4, fd: fd, deadline: deadline, allowRetry: true)
          let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
          guard length <= RielaAppControlLimits.maxResponseFrameBytes, length > 0 else {
            throw ChannelIOError.protocolError
          }
          let body = try ChannelSocket.readExactly(Int(length), fd: fd, deadline: deadline, allowRetry: false)
          let response = try RielaAppControlResponseEnvelope.decodeStrict(body)
          guard response.version == 1, response.requestId == requestId, (100...599).contains(response.status) else {
            throw ChannelIOError.protocolError
          }
          return RielaAppControlResult(status: response.status, body: response.body)
        } catch ChannelIOError.closedBeforeResponse where attempt == 0 {
          continue
        }
      }
      throw ChannelIOError.protocolError
    } catch let error as RielaAppControlChannelError {
      throw error
    } catch ChannelIOError.timeout {
      throw RielaAppControlChannelError.code(.appChannelTimeout)
    } catch ChannelIOError.insecure {
      throw RielaAppControlChannelError.code(.appChannelInsecure)
    } catch ChannelIOError.unavailable {
      throw RielaAppControlChannelError.code(.appChannelUnavailable)
    } catch {
      throw RielaAppControlChannelError.code(.appChannelProtocolError)
    }
  }
}

public enum RielaAppLocalControlProbe {
  public enum Outcome {
    case channel(RielaAppControlChannelClient)
    case notRunning(RielaAppOwnerLock)
  }

  public static func resolve(appRoot: URL) throws -> Outcome {
    let run = RielaAppRunDirectory(appRoot: appRoot)
    _ = try ChannelSocket.address(run.socketURL)
    do {
      try ChannelSocket.validate(run)
      let fd = try ChannelSocket.connect(run.socketURL, timeout: 2)
      close(fd)
      return .channel(RielaAppControlChannelClient(socketURL: run.socketURL))
    } catch ChannelIOError.unavailable(let code) where code == ENOENT || code == ECONNREFUSED {
      do {
        try run.prepare()
        guard let lock = try RielaAppOwnerLock.tryAcquire(run) else {
          throw RielaAppControlChannelError.code(.appChannelUnavailable)
        }
        return .notRunning(lock)
      } catch let error as RielaAppControlChannelError { throw error
      } catch { throw RielaAppControlChannelError.code(.appChannelInsecure) }
    } catch ChannelIOError.insecure {
      throw RielaAppControlChannelError.code(.appChannelInsecure)
    } catch {
      throw RielaAppControlChannelError.code(.appChannelUnavailable)
    }
  }
}
#endif
