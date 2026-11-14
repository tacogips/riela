import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Opens every directory component without following symlinks, then retains
/// the leaf descriptor while a linked native dependency reads it.
final class NativeAddonPinnedFile {
  let descriptor: Int32
  private var snapshot: UnsafeMutablePointer<FILE>?

  init(path: String) throws {
    let url = URL(fileURLWithPath: path)
    let components = url.pathComponents.dropFirst()
    guard let name = components.last else { throw Self.denied() }
    var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw Self.denied() }
    defer { close(parent) }
    for component in components.dropLast() {
      let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw Self.denied() }
      close(parent)
      parent = next
    }
    let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else { throw Self.denied() }
    var status = stat()
    guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
          status.st_nlink == 1, status.st_size >= 0,
          status.st_size <= BuiltinAddonContainerRequest.maximumRecordBytes else {
      close(file)
      throw Self.denied()
    }
    descriptor = file
  }

  deinit {
    if let snapshot { fclose(snapshot) }
    close(descriptor)
  }

  var descriptorPath: String { "/dev/fd/\(descriptor)" }

  func snapshotDescriptorPath() throws -> String {
    if let snapshot {
      rewind(snapshot)
      return "/dev/fd/\(fileno(snapshot))"
    }
    let data = Data(try text().utf8)
    guard let file = tmpfile() else { throw Self.denied() }
    snapshot = file
    let written = data.withUnsafeBytes { buffer in
      fwrite(buffer.baseAddress, 1, buffer.count, file)
    }
    guard written == data.count, fflush(file) == 0 else { throw Self.denied() }
    rewind(file)
    return "/dev/fd/\(fileno(file))"
  }

  func text() throws -> String {
    let data = try readData()
    guard let result = String(data: data, encoding: .utf8) else { throw Self.denied() }
    return result
  }

  func readData() throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0, data.count + count <= BuiltinAddonContainerRequest.maximumRecordBytes else { throw Self.denied() }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }

  private static func denied() -> AdapterExecutionError {
    AdapterExecutionError(.policyBlocked, "native dependency input must be a bounded regular file without symlink traversal")
  }
}
