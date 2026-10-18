#if os(Linux)
import Foundation
import Glibc

@main
enum GoogleDocumentsPOSIXSmoke {
  private static func expectFile(_ url: URL, _ expected: String) throws {
    let bytes = try Data(contentsOf: url)
    precondition(bytes == Data(expected.utf8))
  }

  static func main() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("gateway-posix-\(UUID().uuidString)")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let descriptor = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    precondition(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)

    precondition(Darwin.renameatx_np(descriptor, "first", descriptor, "second", gatewayRenameExclusive) == -1)
    precondition(errno == EEXIST)
    try expectFile(first, "first")
    try expectFile(second, "second")

    precondition(renameatx_np(descriptor, "first", descriptor, "second", gatewayRenameExchange) == 0)
    try expectFile(first, "second")
    try expectFile(second, "first")
    precondition(Darwin.renameatx_np(descriptor, "first", descriptor, "third", gatewayRenameExclusive) == 0)
    precondition(!manager.fileExists(atPath: first.path))
    try expectFile(root.appendingPathComponent("third"), "second")

    precondition(Darwin.renameatx_np(descriptor, "second", descriptor, "third", 0) == -1)
    precondition(errno == EINVAL)
    try expectFile(second, "first")
    precondition(gatewayFlock(descriptor, LOCK_EX | LOCK_NB) == 0)
    precondition(gatewayFlock(descriptor, LOCK_UN) == 0)
    print("Google Documents POSIX exclusive rename, exchange and lock smoke passed")
  }
}
#endif
