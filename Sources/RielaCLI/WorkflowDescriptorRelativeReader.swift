import Darwin
import Foundation

struct WorkflowDescriptorRelativeRead: Sendable {
  var bytes: Data
  var mode: mode_t

  var executable: Bool { mode & 0o111 != 0 }
  var writable: Bool { mode & 0o222 != 0 }
}

enum WorkflowDescriptorRelativeReader {
  static func read(
    _ url: URL,
    within root: URL,
    beforeLeafOpen: @Sendable () throws -> Void = {}
  ) throws -> WorkflowDescriptorRelativeRead {
    let lexicalRoot = root.standardizedFileURL
    let lexicalURL = url.standardizedFileURL
    let prefix = lexicalRoot.path == "/" ? "/" : lexicalRoot.path + "/"
    guard lexicalURL.path.hasPrefix(prefix), lexicalURL.path != lexicalRoot.path else {
      throw CLIUsageError("descriptor-relative file read escapes its selected root")
    }
    let relative = String(lexicalURL.path.dropFirst(prefix.count))
    let components = relative.split(separator: "/").map(String.init)
    guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
      throw CLIUsageError("descriptor-relative file read contains an unsafe path component")
    }

    var descriptor = open(lexicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIUsageError("unable to open descriptor-relative root without following links: \(lexicalRoot.path)")
    }
    defer { _ = close(descriptor) }

    for component in components.dropLast() {
      let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard child >= 0 else {
        throw CLIUsageError("descriptor-relative path component is linked, missing, or not a directory: \(component)")
      }
      _ = close(descriptor)
      descriptor = child
    }

    try beforeLeafOpen()
    let leaf = openat(descriptor, components[components.count - 1], O_RDONLY | O_NOFOLLOW)
    guard leaf >= 0 else {
      throw CLIUsageError("descriptor-relative file is linked, missing, or unreadable: \(lexicalURL.path)")
    }
    defer { _ = close(leaf) }
    var status = stat()
    guard fstat(leaf, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("descriptor-relative file is not a regular file: \(lexicalURL.path)")
    }
    let bytes = try FileHandle(fileDescriptor: leaf, closeOnDealloc: false).readToEnd() ?? Data()
    return WorkflowDescriptorRelativeRead(bytes: bytes, mode: status.st_mode)
  }
}
