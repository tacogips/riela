#if !canImport(Network)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum RielaLocalHTTPServerState: Equatable, Sendable {
  case stopped
  case starting(port: Int)
  case running(port: Int)
  case stopping(port: Int?)
  case failed(message: String)

  public var boundPort: Int? {
    if case let .running(port) = self {
      return port
    }
    return nil
  }
}

public enum RielaLocalHTTPServerError: LocalizedError, Equatable, Sendable {
  case invalidPort(Int)
  case invalidHost(String)
  case unexpectedBoundPort(requested: Int, actual: Int)
  case listenerFailed(String)
  case cancelledBeforeReady

  public var errorDescription: String? {
    switch self {
    case let .invalidPort(port):
      "HTTP listener port must be between 1 and 65535; received \(port)."
    case let .invalidHost(host):
      "HTTP listener host must be an IPv4 address or localhost; received '\(host)'."
    case let .unexpectedBoundPort(requested, actual):
      "HTTP listener bound unexpected port \(actual); requested \(requested)."
    case let .listenerFailed(message):
      "HTTP listener failed: \(message)"
    case .cancelledBeforeReady:
      "HTTP listener stopped before it became ready."
    }
  }
}

public final class RielaLocalHTTPServer: @unchecked Sendable {
  public typealias StateHandler = @Sendable (RielaLocalHTTPServerState) -> Void

  private let routeHandler: any RielaHTTPRouteHandling
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var listenerSocket: Int32 = -1
  private var generation: UInt64 = 0
  private var state = RielaLocalHTTPServerState.stopped
  private var stateHandler: StateHandler?

  public init(
    routeHandler: any RielaHTTPRouteHandling,
    queue: DispatchQueue = DispatchQueue(label: "dev.riela.local-http-server", qos: .userInitiated)
  ) {
    self.routeHandler = routeHandler
    self.queue = queue
  }

  public func setStateHandler(_ handler: StateHandler?) {
    let current: RielaLocalHTTPServerState
    lock.lock()
    stateHandler = handler
    current = state
    lock.unlock()
    handler?(current)
  }

  public var currentState: RielaLocalHTTPServerState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  @discardableResult
  public func start(port: Int) async throws -> Int {
    try await start(host: "127.0.0.1", port: port)
  }

  @discardableResult
  public func start(host: String, port: Int) async throws -> Int {
    try start(host: host, port: port, allowsEphemeralPort: false)
  }

  @discardableResult
  func startForTesting() async throws -> Int {
    try start(host: "127.0.0.1", port: 0, allowsEphemeralPort: true)
  }

  public func stop() async {
    let socketToClose = lock.withLock { () -> Int32 in
      let activeSocket = listenerSocket
      guard activeSocket >= 0 else {
        updateStateLocked(.stopped)
        return -1
      }
      listenerSocket = -1
      generation &+= 1
      updateStateLocked(.stopping(port: state.boundPort))
      return activeSocket
    }
    guard socketToClose >= 0 else {
      return
    }

    _ = shutdown(socketToClose, Int32(SHUT_RDWR))
    _ = close(socketToClose)

    lock.withLock {
      updateStateLocked(.stopped)
    }
  }

  private func start(host: String, port: Int, allowsEphemeralPort: Bool) throws -> Int {
    guard (1...65_535).contains(port) || (allowsEphemeralPort && port == 0) else {
      throw RielaLocalHTTPServerError.invalidPort(port)
    }
    if let runningPort = currentState.boundPort {
      return runningPort
    }

    let socketDescriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard socketDescriptor >= 0 else {
      throw listenerError(operation: "socket")
    }
    do {
      try configure(socket: socketDescriptor, host: host, port: port)
    } catch {
      _ = close(socketDescriptor)
      throw error
    }

    let boundPort = try resolvedPort(socket: socketDescriptor)
    guard allowsEphemeralPort || boundPort == port else {
      _ = close(socketDescriptor)
      throw RielaLocalHTTPServerError.unexpectedBoundPort(requested: port, actual: boundPort)
    }
    lock.lock()
    guard listenerSocket < 0 else {
      lock.unlock()
      _ = close(socketDescriptor)
      throw RielaLocalHTTPServerError.listenerFailed("already starting")
    }
    generation &+= 1
    let activeGeneration = generation
    listenerSocket = socketDescriptor
    updateStateLocked(.running(port: boundPort))
    lock.unlock()

    queue.async { [weak self] in
      self?.acceptConnections(socket: socketDescriptor, generation: activeGeneration)
    }
    return boundPort
  }

  private func configure(socket socketDescriptor: Int32, host: String, port: Int) throws {
    var reuseAddress: Int32 = 1
    guard setsockopt(
      socketDescriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuseAddress,
      socklen_t(MemoryLayout.size(ofValue: reuseAddress))
    ) == 0 else {
      throw listenerError(operation: "setsockopt")
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    let bindingHost = host.caseInsensitiveCompare("localhost") == .orderedSame ? "127.0.0.1" : host
    guard bindingHost.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
      throw RielaLocalHTTPServerError.invalidHost(host)
    }
    let bindResult = withUnsafePointer(to: &address) { addressPointer in
      addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        bind(socketDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      throw listenerError(operation: "bind")
    }
    guard listen(socketDescriptor, SOMAXCONN) == 0 else {
      throw listenerError(operation: "listen")
    }
  }

  private func resolvedPort(socket socketDescriptor: Int32) throws -> Int {
    var address = sockaddr_in()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { addressPointer in
      addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        getsockname(socketDescriptor, socketAddress, &addressLength)
      }
    }
    guard result == 0 else {
      throw listenerError(operation: "getsockname")
    }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  private func acceptConnections(socket socketDescriptor: Int32, generation sourceGeneration: UInt64) {
    while isActive(socket: socketDescriptor, generation: sourceGeneration) {
      let connection = accept(socketDescriptor, nil, nil)
      guard connection >= 0 else {
        if errno == EINTR {
          continue
        }
        return
      }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.receive(from: connection)
      }
    }
  }

  private func receive(from connection: Int32) {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let received = buffer.withUnsafeMutableBytes { bytes in
        recv(connection, bytes.baseAddress, bytes.count, 0)
      }
      guard received > 0 else {
        send(.text(status: 400, "Incomplete HTTP request"), method: "GET", through: connection)
        return
      }
      data.append(contentsOf: buffer.prefix(received))
      do {
        switch try RielaHTTPRequestParser().parse(data) {
        case .incomplete:
          continue
        case let .complete(request):
          Task { [self] in
            let response = await self.routeHandler.response(for: request)
            self.send(response, method: request.method, through: connection)
          }
          return
        }
      } catch let parserError as RielaHTTPRequestParserError {
        send(
          .text(status: parserError.status, parserError.localizedDescription),
          method: "GET",
          through: connection
        )
        return
      } catch {
        send(.text(status: 400, "Bad Request"), method: "GET", through: connection)
        return
      }
    }
  }

  private func send(_ response: RielaHTTPResponse, method: String, through connection: Int32) {
    let data = response.serialized(forMethod: method)
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var sentBytes = 0
      while sentBytes < bytes.count {
        #if canImport(Glibc)
        let result = Glibc.send(
          connection,
          baseAddress.advanced(by: sentBytes),
          bytes.count - sentBytes,
          Int32(MSG_NOSIGNAL)
        )
        #elseif canImport(Musl)
        let result = Musl.send(
          connection,
          baseAddress.advanced(by: sentBytes),
          bytes.count - sentBytes,
          Int32(MSG_NOSIGNAL)
        )
        #endif
        guard result > 0 else { break }
        sentBytes += result
      }
    }
    _ = shutdown(connection, Int32(SHUT_RDWR))
    _ = close(connection)
  }

  private func isActive(socket socketDescriptor: Int32, generation sourceGeneration: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return listenerSocket == socketDescriptor && generation == sourceGeneration
  }

  private func updateStateLocked(_ newState: RielaLocalHTTPServerState) {
    state = newState
    let callback = stateHandler
    if let callback {
      queue.async {
        callback(newState)
      }
    }
  }

  private func listenerError(operation: String) -> RielaLocalHTTPServerError {
    let detail = String(cString: strerror(errno))
    return .listenerFailed("\(operation): \(detail)")
  }
}
#endif
