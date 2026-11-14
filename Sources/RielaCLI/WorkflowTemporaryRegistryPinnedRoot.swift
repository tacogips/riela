#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct WorkflowTemporaryRegistryInventoryEntry: Sendable {
  var relativePath: String
  var bytes: Data?
  var mode: mode_t
}

struct WorkflowTemporaryRegistryRootAbsent: Error {}

/// Pins the temporary-workflow registry below the selected home directory and
/// resolves every registry-owned child through directory descriptors.
final class WorkflowTemporaryRegistryPinnedRoot: @unchecked Sendable {
  let url: URL
  private let lexicalRoot: URL
  private let descriptor: Int32
  private let device: dev_t
  private let inode: ino_t

  init(homeDirectory: URL, create: Bool) throws {
    let lexicalHome = homeDirectory.standardizedFileURL
    guard let resolvedPointer = realpath(lexicalHome.path, nil) else {
      throw CLIUsageError("unable to resolve temporary workflow registry home")
    }
    defer { free(resolvedPointer) }
    let resolvedHome = URL(
      fileURLWithPath: String(cString: resolvedPointer),
      isDirectory: true
    ).standardizedFileURL
    var current = open(resolvedHome.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard current >= 0 else {
      throw CLIUsageError("unable to pin temporary workflow registry home")
    }
    do {
      for component in [".riela", "temporary-workflows"] {
        if create, mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
          throw CLIUsageError("unable to create temporary workflow registry root")
        }
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard next >= 0 else {
          if !create, errno == ENOENT { throw WorkflowTemporaryRegistryRootAbsent() }
          throw CLIUsageError("temporary workflow registry root contains a linked or non-directory component")
        }
        _ = close(current)
        current = next
      }
      descriptor = current
      var status = stat()
      guard fstat(descriptor, &status) == 0 else {
        throw CLIUsageError("unable to inspect pinned temporary workflow registry root")
      }
      device = status.st_dev
      inode = status.st_ino
    } catch {
      _ = close(current)
      throw error
    }
    lexicalRoot = lexicalHome
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("temporary-workflows", isDirectory: true)
      .standardizedFileURL
    url = resolvedHome
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("temporary-workflows", isDirectory: true)
      .standardizedFileURL
  }

  deinit { _ = close(descriptor) }

  func requireConfiguredPathIdentity() throws {
    let current = open(lexicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard current >= 0 else {
      throw CLIUsageError("temporary workflow registry root changed while an operation was active")
    }
    defer { _ = close(current) }
    var status = stat()
    guard fstat(current, &status) == 0,
          status.st_dev == device,
          status.st_ino == inode else {
      throw CLIUsageError("temporary workflow registry root changed while an operation was active")
    }
  }

  func bundleInventory(in child: URL) throws -> [WorkflowTemporaryRegistryInventoryEntry] {
    let directory = try openDirectory(relativePath(for: child))
    defer { _ = close(directory) }
    var entries: [WorkflowTemporaryRegistryInventoryEntry] = []
    try inventory(descriptor: directory, prefix: "", entries: &entries)
    return entries.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
  }

  func ensureDirectory(_ child: URL) throws {
    let directory = try openDirectory(relativePath(for: child), create: true)
    _ = close(directory)
  }

  func openDirectory(_ relative: String, create: Bool = false) throws -> Int32 {
    if relative.isEmpty { return dup(descriptor) }
    try validate(relative)
    var current = dup(descriptor)
    guard current >= 0 else { throw CLIUsageError("unable to duplicate temporary registry root") }
    do {
      for component in relative.split(separator: "/").map(String.init) {
        if create, mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
          throw CLIUsageError("unable to create temporary registry directory")
        }
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard next >= 0 else {
          throw CLIUsageError("temporary registry path contains a linked or non-directory component")
        }
        _ = close(current)
        current = next
      }
      return current
    } catch {
      _ = close(current)
      throw error
    }
  }

  func entryType(_ child: URL) throws -> mode_t? {
    let relative = try relativePath(for: child)
    let components = relative.split(separator: "/").map(String.init)
    guard let leaf = components.last else { throw CLIUsageError("temporary registry leaf is required") }
    guard let parent = try openDirectoryIfPresent(components.dropLast().joined(separator: "/")) else {
      return nil
    }
    defer { _ = close(parent) }
    var status = stat()
    if fstatat(parent, leaf, &status, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return nil }
      throw CLIUsageError("unable to inspect temporary registry entry")
    }
    guard status.st_mode & S_IFMT != S_IFLNK else {
      throw CLIUsageError("temporary workflow transaction record is linked or malformed")
    }
    return status.st_mode & S_IFMT
  }

  func openRegularFile(
    _ child: URL,
    flags: Int32,
    permissions: mode_t = S_IRUSR | S_IWUSR
  ) throws -> Int32 {
    try withParent(of: child) { parent, leaf in
      let file = openat(parent, leaf, flags | O_NOFOLLOW, permissions)
      guard file >= 0 else {
        throw CLIUsageError("temporary registry file is linked, missing, or inaccessible")
      }
      var status = stat()
      guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
        _ = close(file)
        throw CLIUsageError("temporary registry file has unexpected type")
      }
      return file
    }
  }

  func readRegularIfPresent(_ child: URL) throws -> Data? {
    do {
      let file = try openRegularFile(child, flags: O_RDONLY)
      defer { _ = close(file) }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4_096)
      while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
          read(file, bytes.baseAddress, bytes.count)
        }
        guard count >= 0 else { throw CLIUsageError("unable to read temporary registry record") }
        if count == 0 { return data }
        data.append(contentsOf: buffer.prefix(Int(count)))
      }
    } catch {
      if try entryType(child) == nil { return nil }
      throw error
    }
  }

  func writeNewRegularFile(_ data: Data, to child: URL, permissions: mode_t = S_IRUSR | S_IWUSR) throws {
    let file = try openRegularFile(
      child,
      flags: O_WRONLY | O_CREAT | O_EXCL,
      permissions: permissions
    )
    var succeeded = false
    defer {
      _ = close(file)
      if !succeeded { try? unlink(child) }
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(file, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { throw CLIUsageError("unable to write temporary registry file") }
        offset += count
      }
    }
    guard fsync(file) == 0 else { throw CLIUsageError("unable to sync temporary registry file") }
    succeeded = true
  }

  func rename(_ source: URL, to destination: URL) throws {
    let sourceRelative = try relativePath(for: source)
    let destinationRelative = try relativePath(for: destination)
    let sourceParts = sourceRelative.split(separator: "/").map(String.init)
    let destinationParts = destinationRelative.split(separator: "/").map(String.init)
    guard let sourceLeaf = sourceParts.last, let destinationLeaf = destinationParts.last else {
      throw CLIUsageError("temporary registry rename requires child paths")
    }
    let sourceParent = try openDirectory(sourceParts.dropLast().joined(separator: "/"))
    defer { _ = close(sourceParent) }
    let destinationParent = try openDirectory(destinationParts.dropLast().joined(separator: "/"))
    defer { _ = close(destinationParent) }
    guard renameat(sourceParent, sourceLeaf, destinationParent, destinationLeaf) == 0 else {
      throw CLIUsageError("temporary workflow registry publication rename failed: \(String(cString: strerror(errno)))")
    }
    guard fsync(sourceParent) == 0 else { throw CLIUsageError("unable to sync temporary registry directory") }
    if sourceParent != destinationParent, fsync(destinationParent) != 0 {
      throw CLIUsageError("unable to sync temporary registry directory")
    }
  }

  func remove(_ child: URL) throws {
    try withParent(of: child) { parent, leaf in
      try validateRemovableTree(parent: parent, leaf: leaf)
      try remove(parent: parent, leaf: leaf)
      guard fsync(parent) == 0 else { throw CLIUsageError("unable to sync temporary registry directory") }
    }
  }

  func unlink(_ child: URL) throws {
    try withParent(of: child) { parent, leaf in
      if unlinkat(parent, leaf, 0) != 0, errno != ENOENT {
        throw CLIUsageError("unable to remove temporary registry file")
      }
      guard fsync(parent) == 0 else { throw CLIUsageError("unable to sync temporary registry directory") }
    }
  }

  func syncDirectory(_ child: URL) throws {
    let directory = try openDirectory(relativePath(for: child))
    defer { _ = close(directory) }
    guard fsync(directory) == 0 else { throw CLIUsageError("unable to sync temporary registry directory") }
  }

  func names(in child: URL) throws -> [String] {
    let directoryDescriptor = try openDirectory(relativePath(for: child))
    guard let directory = fdopendir(directoryDescriptor) else {
      _ = close(directoryDescriptor)
      throw CLIUsageError("unable to enumerate temporary registry directory")
    }
    defer { closedir(directory) }
    var result: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != ".", name != ".." { result.append(name) }
    }
    return result.sorted()
  }

  private func withParent<T>(of child: URL, _ body: (Int32, String) throws -> T) throws -> T {
    let relative = try relativePath(for: child)
    let components = relative.split(separator: "/").map(String.init)
    guard let leaf = components.last else { throw CLIUsageError("temporary registry leaf is required") }
    let parent = try openDirectory(components.dropLast().joined(separator: "/"))
    defer { _ = close(parent) }
    return try body(parent, leaf)
  }

  private func openDirectoryIfPresent(_ relative: String) throws -> Int32? {
    if relative.isEmpty { return dup(descriptor) }
    try validate(relative)
    var current = dup(descriptor)
    guard current >= 0 else { throw CLIUsageError("unable to duplicate temporary registry root") }
    for component in relative.split(separator: "/").map(String.init) {
      let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      if next < 0 {
        let failure = errno
        _ = close(current)
        if failure == ENOENT { return nil }
        throw CLIUsageError("temporary registry path contains a linked or non-directory component")
      }
      _ = close(current)
      current = next
    }
    return current
  }

  private func remove(parent: Int32, leaf: String) throws {
    var status = stat()
    guard fstatat(parent, leaf, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw CLIUsageError("unable to inspect temporary registry artifact")
    }
    let kind = status.st_mode & S_IFMT
    guard kind != S_IFLNK else {
      throw CLIUsageError("refusing to remove a linked temporary registry artifact")
    }
    if kind == S_IFREG {
      guard unlinkat(parent, leaf, 0) == 0 else {
        throw CLIUsageError("unable to remove temporary registry file")
      }
      return
    }
    guard kind == S_IFDIR else {
      throw CLIUsageError("refusing to remove a special temporary registry artifact")
    }
    let child = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard child >= 0 else { throw CLIUsageError("unable to open temporary registry directory") }
    var closed = false
    do {
      for name in try names(descriptor: child) {
        try remove(parent: child, leaf: name)
      }
      guard fsync(child) == 0 else { throw CLIUsageError("unable to sync temporary registry directory") }
      _ = close(child)
      closed = true
      guard unlinkat(parent, leaf, AT_REMOVEDIR) == 0 else {
        throw CLIUsageError("unable to remove temporary registry directory")
      }
    } catch {
      if !closed { _ = close(child) }
      throw error
    }
  }

  private func validateRemovableTree(parent: Int32, leaf: String) throws {
    var status = stat()
    guard fstatat(parent, leaf, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw CLIUsageError("unable to inspect temporary registry artifact")
    }
    let kind = status.st_mode & S_IFMT
    guard kind != S_IFLNK else {
      throw CLIUsageError("refusing to remove a linked temporary registry artifact")
    }
    if kind == S_IFREG { return }
    guard kind == S_IFDIR else {
      throw CLIUsageError("refusing to remove a special temporary registry artifact")
    }
    let child = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard child >= 0 else { throw CLIUsageError("unable to open temporary registry directory") }
    defer { _ = close(child) }
    for name in try names(descriptor: child) {
      try validateRemovableTree(parent: child, leaf: name)
    }
  }

  private func names(descriptor: Int32) throws -> [String] {
    let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { _ = close(duplicate) }
      throw CLIUsageError("unable to enumerate temporary registry directory")
    }
    defer { closedir(directory) }
    var result: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != ".", name != ".." { result.append(name) }
    }
    return result.sorted()
  }

  private func inventory(
    descriptor: Int32,
    prefix: String,
    entries: inout [WorkflowTemporaryRegistryInventoryEntry]
  ) throws {
    for name in try names(descriptor: descriptor) {
      var status = stat()
      guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw CLIUsageError("temporary workflow bundle entry disappeared during inventory")
      }
      let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
      switch status.st_mode & S_IFMT {
      case S_IFDIR:
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else {
          throw CLIUsageError("temporary workflow bundle directory is linked or inaccessible")
        }
        entries.append(WorkflowTemporaryRegistryInventoryEntry(
          relativePath: relative,
          bytes: nil,
          mode: status.st_mode
        ))
        do {
          try inventory(descriptor: child, prefix: relative, entries: &entries)
          _ = close(child)
        } catch {
          _ = close(child)
          throw error
        }
      case S_IFREG:
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else {
          throw CLIUsageError("temporary workflow bundle file is linked or inaccessible")
        }
        var openedStatus = stat()
        guard fstat(file, &openedStatus) == 0,
              openedStatus.st_mode & S_IFMT == S_IFREG,
              openedStatus.st_dev == status.st_dev,
              openedStatus.st_ino == status.st_ino else {
          _ = close(file)
          throw CLIUsageError("temporary workflow bundle entry changed during inventory")
        }
        let bytes: Data
        do {
          bytes = try FileHandle(fileDescriptor: file, closeOnDealloc: false).readToEnd() ?? Data()
          _ = close(file)
        } catch {
          _ = close(file)
          throw error
        }
        entries.append(WorkflowTemporaryRegistryInventoryEntry(
          relativePath: relative,
          bytes: bytes,
          mode: openedStatus.st_mode
        ))
      default:
        throw CLIUsageError("temporary workflow bundle inventory contains a linked or special entry")
      }
    }
  }

  private func relativePath(for child: URL) throws -> String {
    let standardized = child.standardizedFileURL
    guard standardized.path != lexicalRoot.path,
          standardized.path.hasPrefix(lexicalRoot.path + "/") else {
      if standardized.path == lexicalRoot.path { return "" }
      throw CLIUsageError("temporary registry path escapes its pinned root")
    }
    let relative = String(standardized.path.dropFirst(lexicalRoot.path.count + 1))
    try validate(relative)
    return relative
  }

  private func validate(_ relative: String) throws {
    guard !relative.hasPrefix("/"), !relative.isEmpty else {
      if relative.isEmpty { return }
      throw CLIUsageError("temporary registry path must be relative")
    }
    let components = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
      throw CLIUsageError("temporary registry path contains an unsafe component")
    }
  }
}
