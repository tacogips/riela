import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class NativeAddonPinnedDirectory {
  private let descriptor: Int32
  private let stagingDirectory: URL

  enum StagingContext {
    @TaskLocal static var root: URL?
  }

  init(path: String, exposedRoots: [String]) throws {
    let stagingRoot = (StagingContext.root ?? FileManager.default.temporaryDirectory).resolvingSymlinksInPath()
    let staging = stagingRoot.appendingPathComponent("riela-native-\(UUID().uuidString)", isDirectory: true)
    guard !exposedRoots.contains(where: { staging.path == $0 || staging.path.hasPrefix($0 + "/") }) else { throw Self.denied() }
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    stagingDirectory = staging
    var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else {
      try? FileManager.default.removeItem(at: staging)
      throw Self.denied()
    }
    do {
      for component in URL(fileURLWithPath: path).pathComponents.dropFirst() {
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw Self.denied() }
        close(directory)
        directory = next
      }
      descriptor = directory
    } catch {
      close(directory)
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  deinit {
    close(descriptor)
    try? FileManager.default.removeItem(at: stagingDirectory)
  }

  var descriptorPath: String { stagingDirectory.path }

  func publishFiles(deadline: Date?) throws {
    for url in try FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
      let source = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard source >= 0 else { throw Self.denied() }
      defer { close(source) }
      var status = stat()
      guard fstat(source, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else { throw Self.denied() }
      let destination = openat(descriptor, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard destination >= 0 else { throw Self.denied() }
      defer { close(destination) }
      var remaining = status.st_size
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while remaining > 0 {
        if let deadline, Date() >= deadline { throw AdapterExecutionError(.timeout, "native file transfer exceeded its deadline") }
        let count = read(source, &buffer, min(buffer.count, Int(min(remaining, 65_536))))
        guard count > 0 else { throw Self.denied() }
        try buffer.withUnsafeBytes { bytes in
          guard let address = bytes.baseAddress else { throw Self.denied() }
          var offset = 0
          while offset < count {
            let written = write(destination, address.advanced(by: offset), count - offset)
            guard written > 0 else { throw Self.denied() }
            offset += written
          }
        }
        remaining -= off_t(count)
      }
      guard fsync(destination) == 0 else { throw Self.denied() }
    }
  }

  private static func denied() -> AdapterExecutionError {
    AdapterExecutionError(.policyBlocked, "native output directory must not follow symbolic links")
  }
}
