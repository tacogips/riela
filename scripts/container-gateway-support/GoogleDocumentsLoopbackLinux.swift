private final class LoopbackCallback {
  private var socketFD: Int32 = -1

  func start(timeout: TimeInterval) throws -> UInt16 {
    guard timeout.isFinite, timeout > 0 else { throw GatewayError.transportFailure("OAuth callback timeout is invalid") }
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard descriptor >= 0 else { throw GatewayError.transportFailure("OAuth callback socket failed") }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(descriptor, 8) == 0 else {
      close(descriptor)
      throw GatewayError.transportFailure("OAuth callback bind failed")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let resolved = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard resolved == 0 else {
      close(descriptor)
      throw GatewayError.transportFailure("OAuth callback port resolution failed")
    }
    socketFD = descriptor
    return UInt16(bigEndian: address.sin_port)
  }

  func wait(timeout: TimeInterval) throws -> LoopbackResult {
    guard timeout.isFinite, timeout > 0 else { throw GatewayError.transportFailure("OAuth login timeout is invalid") }
    let deadline = Date().addingTimeInterval(timeout)
    for _ in 0..<32 {
      try waitForInput(socketFD, deadline: deadline)
      var peer = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let client = withUnsafeMutablePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(socketFD, $0, &length) }
      }
      guard client >= 0 else { throw GatewayError.transportFailure("OAuth callback accept failed") }
      defer { close(client) }
      guard peer.sin_addr.s_addr == inet_addr("127.0.0.1") else { continue }
      let connectionDeadline = min(deadline, Date().addingTimeInterval(1))
      var bytes = Data()
      while bytes.count < 16 * 1024, bytes.range(of: Data("\r\n\r\n".utf8)) == nil {
        try waitForInput(client, deadline: connectionDeadline)
        var buffer = [UInt8](repeating: 0, count: 1_024)
        let count = read(client, &buffer, min(buffer.count, 16 * 1024 - bytes.count))
        guard count > 0 else { break }
        bytes.append(buffer, count: count)
      }
      guard let result = parseLoopbackRequest(bytes) else { continue }
      let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
      _ = response.withCString { send(client, $0, strlen($0), Int32(MSG_NOSIGNAL)) }
      return result
    }
    throw GatewayError.transportFailure("OAuth callback request limit exceeded")
  }

  func cancel() {
    if socketFD >= 0 { close(socketFD); socketFD = -1 }
  }

  deinit { cancel() }

  private func waitForInput(_ descriptor: Int32, deadline: Date) throws {
    while Date() < deadline {
      var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let milliseconds = Int32(min(1_000, max(1, deadline.timeIntervalSinceNow * 1_000)))
      let result = poll(&item, 1, milliseconds)
      if result < 0, errno == EINTR { continue }
      if result > 0, item.revents & Int16(POLLIN) != 0 { return }
      guard result >= 0, item.revents & Int16(POLLERR | POLLNVAL | POLLHUP) == 0 else {
        throw GatewayError.transportFailure("OAuth callback connection failed")
      }
    }
    throw GatewayError.transportFailure("OAuth login timed out")
  }
}
