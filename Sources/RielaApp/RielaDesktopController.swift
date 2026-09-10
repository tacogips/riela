#if os(macOS)
import AppKit
import Foundation
import RielaServer

/// Owns a Tauri child window. The inherited pipes never expose an HTTP listener.
@MainActor
final class RielaDesktopController {
  private weak var app: RielaApp?
  private var process: Process?
  private var input: DesktopPipeWriter?
  private let csrfToken = UUID().uuidString

  init(app: RielaApp) {
    self.app = app
  }

  func open() async throws {
    if let process, process.isRunning {
      try await send(Data("{\"action\":\"show\"}\n".utf8))
      return
    }
    let executable = try executableURL()
    let child = Process()
    child.executableURL = executable
    var environment = ProcessInfo.processInfo.environment
    environment["RIELA_DESKTOP_IPC"] = "stdio"
    child.environment = environment
    let requests = Pipe()
    let responses = Pipe()
    child.standardOutput = requests
    child.standardInput = responses
    child.standardError = FileHandle.standardError
    let reader = DesktopFrameReader()
    requests.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      do {
        for frame in try reader.append(data) {
          Task { @MainActor [weak self] in
            await self?.respond(to: frame, child: child)
          }
        }
      } catch {
        handle.readabilityHandler = nil
        child.terminate()
      }
    }
    child.terminationHandler = { [weak self] terminated in
      requests.fileHandleForReading.readabilityHandler = nil
      Task { @MainActor [weak self] in
        guard let self, self.process === terminated else { return }
        self.input = nil
        self.process = nil
      }
    }
    do {
      try child.run()
      process = child
      input = DesktopPipeWriter(handle: responses.fileHandleForWriting)
    } catch {
      requests.fileHandleForReading.readabilityHandler = nil
      throw error
    }
  }

  func shutdown() {
    input?.close()
    input = nil
    if process?.isRunning == true { process?.terminate() }
    process = nil
  }

  private func respond(to data: Data, child: Process) async {
    guard process === child, let app,
          let message = try? JSONDecoder().decode(DesktopRequestFrame.self, from: data) else { return }
    let response = await app.desktopAPIResponse(for: message.request, csrfToken: csrfToken)
    guard process === child else { return }
    let reply = DesktopResponseFrame(
      id: message.id,
      response: DesktopResponseFrame.Response(
        status: response.status,
        headers: response.headers,
        body: response.body.base64EncodedString()
      )
    )
    do {
      var encoded = try JSONEncoder().encode(reply)
      encoded.append(0x0A)
      try await send(encoded)
    } catch {
      shutdown()
    }
  }

  private func send(_ data: Data) async throws {
    guard let input else { throw CocoaError(.fileWriteUnknown) }
    try await input.send(data)
  }

  private func executableURL() throws -> URL {
    var candidates: [URL] = []
    if let override = ProcessInfo.processInfo.environment["RIELA_DESKTOP_EXECUTABLE"] {
      candidates.append(URL(fileURLWithPath: override))
    }
    if let executable = Bundle.main.executableURL {
      candidates.append(
        executable.deletingLastPathComponent()
          .appendingPathComponent("../Helpers/RielaDesktop.app/Contents/MacOS/riela-desktop")
          .standardizedFileURL
      )
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for configuration in ["debug", "release"] {
      candidates.append(root.appendingPathComponent("web/src-tauri/target/\(configuration)/riela-desktop"))
    }
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      throw NSError(
        domain: "RielaDesktop", code: 1,
        userInfo: [NSLocalizedDescriptionKey:
          "Tauri window executable is missing. Run bun run desktop:build in web/, or rebuild RielaApp.app."]
      )
    }
    return executable
  }
}

private struct DesktopRequestFrame: Decodable {
  let id: UInt64
  let request: RielaDesktopRequest
}

private struct DesktopResponseFrame: Encodable {
  struct Response: Encodable {
    let status: Int
    let headers: [String: String]
    let body: String
  }
  let id: UInt64
  let response: Response
}

/// FileHandle can deliver partial or coalesced frames on its reader queue.
private final class DesktopFrameReader: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()

  func append(_ data: Data) throws -> [Data] {
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
    var frames: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      guard buffer.distance(from: buffer.startIndex, to: newline) <= 16 * 1024 * 1024 else {
        throw CocoaError(.fileReadTooLarge)
      }
      frames.append(Data(buffer[..<newline]))
      buffer.removeSubrange(...newline)
    }
    guard buffer.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
    return frames
  }
}
#endif

#if os(macOS)
/// A stalled child must never block AppKit's main actor while writing a large response.
private final class DesktopPipeWriter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "riela.desktop.responses")
  private let handle: FileHandle

  init(handle: FileHandle) { self.handle = handle }

  func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [handle] in
        do {
          try handle.write(contentsOf: data)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func close() {
    queue.async { [handle] in try? handle.close() }
  }
}
#endif
