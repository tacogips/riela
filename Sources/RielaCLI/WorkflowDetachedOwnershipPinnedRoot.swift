#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

private struct WorkflowDetachedInventoryEntry {
  var relativePath: String
  var bytes: Data?
  var mode: mode_t
}

/// Retains the verified detached ownership container for the full recovery
/// operation so later checks and mutations cannot be redirected by replacing
/// its lexical path.
final class WorkflowDetachedOwnershipPinnedRoot: @unchecked Sendable {
  let identity: WorkflowDetachedOwnershipRootIdentity
  private var descriptor: Int32

  init(candidate: URL, requireRoot: Bool) throws {
    let root = try WorkflowDetachedOwnershipRoot.validateCanonicalPath(candidate)
    let container = root.deletingLastPathComponent()
    let namespace = WorkflowDetachedOwnershipRoot.canonicalNamespaceRoot
    let name = container.lastPathComponent
    let namespaceRoot = try WorkflowHistoryPinnedRoot(namespace, create: false)
    descriptor = try namespaceRoot.openDirectory(name)
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_uid == geteuid(),
          status.st_mode & S_IFMT == S_IFDIR,
          status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
      _ = close(descriptor)
      descriptor = -1
      throw CLIUsageError("detached workflow ownership container has unsafe identity or permissions")
    }
    identity = WorkflowDetachedOwnershipRootIdentity(
      root: root,
      containerDevice: UInt64(truncatingIfNeeded: status.st_dev),
      containerInode: UInt64(truncatingIfNeeded: status.st_ino)
    )
    if requireRoot {
      let rootDescriptor = try openDirectory("root")
      _ = close(rootDescriptor)
    }
  }

  deinit {
    if descriptor >= 0 { _ = close(descriptor) }
  }

  func requireConfiguredPathIdentity() throws {
    let containerName = identity.root.deletingLastPathComponent().lastPathComponent
    let namespace = try WorkflowHistoryPinnedRoot(
      WorkflowDetachedOwnershipRoot.canonicalNamespaceRoot,
      create: false
    )
    let current = try namespace.openDirectory(containerName)
    defer { _ = close(current) }
    var status = stat()
    guard fstat(current, &status) == 0,
          UInt64(truncatingIfNeeded: status.st_dev) == identity.containerDevice,
          UInt64(truncatingIfNeeded: status.st_ino) == identity.containerInode else {
      throw CLIUsageError("detached workflow ownership container changed while recovery was active")
    }
  }

  func directoryExists(_ name: String) throws -> Bool {
    try validateLeaf(name)
    var status = stat()
    if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return false }
      throw CLIUsageError("unable to inspect detached workflow transaction tree")
    }
    guard status.st_mode & S_IFMT == S_IFDIR else {
      throw CLIUsageError("detached workflow transaction tree is linked or has unexpected type")
    }
    return true
  }

  func stableDirectoryURL(_ name: String) throws -> URL {
    guard try directoryExists(name) else {
      throw CLIUsageError("detached workflow transaction directory is missing")
    }
    #if canImport(Darwin)
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
      throw CLIUsageError("unable to resolve the retained detached workflow container")
    }
    guard let descriptorRoot = String(
      data: Data(buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }),
      encoding: .utf8
    ) else {
      throw CLIUsageError("retained detached workflow container has a non-UTF-8 path")
    }
    #else
    let link = "/proc/self/fd/\(descriptor)"
    var buffer = [CChar](repeating: 0, count: 4_096)
    let count = readlink(link, &buffer, buffer.count - 1)
    guard count > 0 else {
      throw CLIUsageError("unable to resolve the retained detached workflow container")
    }
    buffer[Int(count)] = 0
    guard let descriptorRoot = String(
      data: Data(buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }),
      encoding: .utf8
    ) else {
      throw CLIUsageError("retained detached workflow container has a non-UTF-8 path")
    }
    #endif
    return URL(fileURLWithPath: descriptorRoot, isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
      .resolvingSymlinksInPath()
      .standardizedFileURL
  }

  func readRegularFile(_ relativePath: String, in directory: String) throws -> Data {
    try validateRelativePath(relativePath)
    let components = relativePath.split(separator: "/").map(String.init)
    guard let leaf = components.last else {
      throw CLIUsageError("detached workflow file path is required")
    }
    let parentPath = ([directory] + components.dropLast()).joined(separator: "/")
    let parent = try openDirectory(parentPath)
    defer { _ = close(parent) }
    return try readRegular(parent: parent, name: leaf)
  }

  func copyDirectory(from source: String, to destination: String) throws {
    try validateLeaf(source)
    try validateLeaf(destination)
    guard try directoryExists(source), try !entryExists(destination) else {
      throw CLIUsageError("detached workflow copy paths are not verified siblings")
    }
    let sourceDescriptor = try openDirectory(source)
    defer { _ = close(sourceDescriptor) }
    var sourceStatus = stat()
    guard fstat(sourceDescriptor, &sourceStatus) == 0,
          mkdirat(descriptor, destination, sourceStatus.st_mode & 0o777) == 0 else {
      throw CLIUsageError("unable to create detached workflow transaction staging directory")
    }
    var entries: [WorkflowDetachedInventoryEntry] = []
    try inventory(descriptor: sourceDescriptor, prefix: "", entries: &entries)
    for entry in entries {
      let path = "\(destination)/\(entry.relativePath)"
      if let bytes = entry.bytes {
        try write(bytes, to: path, mode: entry.mode)
      } else {
        try ensureDirectory(path, mode: entry.mode)
      }
    }
    try sync()
  }

  func populateRoot(with entries: [WorkflowMutableRegistryInventoryEntry]) throws {
    for entry in entries {
      let path = "root/\(entry.relativePath)"
      if let bytes = entry.bytes {
        try write(bytes, to: path, mode: entry.mode)
      } else {
        try ensureDirectory(path, mode: entry.mode)
      }
    }
    try syncTree("root")
  }

  func inventory(for target: WorkflowBundleIdentity, directory name: String) throws -> WorkflowBundleInventory {
    let source = try openDirectory(name)
    defer { _ = close(source) }
    var entries: [WorkflowDetachedInventoryEntry] = []
    try inventory(descriptor: source, prefix: "", entries: &entries)
    let snapshotRoot = try WorkflowDetachedOwnershipRoot.create()
    let snapshot = try WorkflowDetachedOwnershipPinnedRoot(candidate: snapshotRoot, requireRoot: true)
    defer { try? snapshot.destroyContainer() }
    for entry in entries {
      if let bytes = entry.bytes {
        try snapshot.write(bytes, to: "root/\(entry.relativePath)", mode: entry.mode)
      } else {
        try snapshot.ensureDirectory("root/\(entry.relativePath)", mode: entry.mode)
      }
    }
    try snapshot.requireConfiguredPathIdentity()
    let result = try WorkflowHistoryIdentityResolver.inventory(for: target, rootOverride: snapshotRoot)
    try snapshot.requireConfiguredPathIdentity()
    return result
  }

  func readCanonicalIfPresent<T: Codable>(_ type: T.Type, name: String) throws -> T? {
    let sidecar = name + ".sha256"
    let recordExists = try regularFileExists(name)
    let sidecarExists = try regularFileExists(sidecar)
    guard recordExists == sidecarExists else {
      throw CLIUsageError("detached workflow stable marker record and sidecar are incomplete")
    }
    guard recordExists else { return nil }
    let bytes = try readRegular(name)
    let digest = try readRegular(sidecar)
    guard digest == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    return try WorkflowHistoryCanonicalCoding.decode(type, from: bytes)
  }

  func writeCanonical<T: Encodable>(_ value: T, name: String) throws {
    try validateLeaf(name)
    let bytes = try WorkflowHistoryCanonicalCoding.encode(value)
    try write(bytes, to: name, mode: S_IRUSR | S_IWUSR)
    try write(
      Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8),
      to: name + ".sha256",
      mode: S_IRUSR | S_IWUSR
    )
    try sync()
  }

  func removePersistedRecord(name: String) throws {
    let sidecar = name + ".sha256"
    let recordExists = try regularFileExists(name)
    let sidecarExists = try regularFileExists(sidecar)
    guard recordExists == sidecarExists else {
      throw CLIUsageError("detached workflow stable marker record and sidecar are incomplete")
    }
    guard recordExists else { return }
    guard unlinkat(descriptor, name, 0) == 0,
          unlinkat(descriptor, sidecar, 0) == 0,
          fsync(descriptor) == 0 else {
      throw CLIUsageError("unable to remove detached workflow stable marker")
    }
  }

  func removeDirectory(_ name: String) throws {
    try validateLeaf(name)
    try validateRemovableTree(parent: descriptor, leaf: name)
    try remove(parent: descriptor, leaf: name)
    try sync()
  }

  func renameDirectory(from source: String, to destination: String) throws {
    guard try directoryExists(source), try !entryExists(destination) else {
      throw CLIUsageError("detached workflow transaction rename paths are not verified siblings")
    }
    guard renameat(descriptor, source, descriptor, destination) == 0 else {
      throw CLIUsageError("unable to rename detached workflow transaction directory")
    }
  }

  func sync() throws {
    guard fsync(descriptor) == 0 else {
      throw CLIUsageError("unable to sync detached workflow ownership container")
    }
  }

  func syncTree(_ name: String) throws {
    let root = try openDirectory(name)
    defer { _ = close(root) }
    try syncTree(descriptor: root)
    try sync()
  }

  func destroyContainer() throws {
    try requireConfiguredPathIdentity()
    let containerName = identity.root.deletingLastPathComponent().lastPathComponent
    try removeDirectory("root")
    let currentDescriptor = descriptor
    descriptor = -1
    _ = close(currentDescriptor)
    let namespace = try WorkflowHistoryPinnedRoot(
      WorkflowDetachedOwnershipRoot.canonicalNamespaceRoot,
      create: false
    )
    var status = stat()
    guard fstatat(namespace.descriptor, containerName, &status, AT_SYMLINK_NOFOLLOW) == 0,
          UInt64(truncatingIfNeeded: status.st_dev) == identity.containerDevice,
          UInt64(truncatingIfNeeded: status.st_ino) == identity.containerInode,
          unlinkat(namespace.descriptor, containerName, AT_REMOVEDIR) == 0 else {
      throw CLIUsageError("detached workflow inventory snapshot changed before cleanup")
    }
  }

  private func openDirectory(_ relativePath: String) throws -> Int32 {
    try validateRelativePath(relativePath)
    var current = dup(descriptor)
    guard current >= 0 else { throw CLIUsageError("unable to duplicate detached workflow container") }
    do {
      for component in relativePath.split(separator: "/").map(String.init) {
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard next >= 0 else {
          throw CLIUsageError("detached workflow directory is missing, linked, or inaccessible")
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

  private func ensureDirectory(_ relativePath: String, mode: mode_t) throws {
    try validateRelativePath(relativePath)
    var current = dup(descriptor)
    guard current >= 0 else { throw CLIUsageError("unable to duplicate detached workflow container") }
    defer { _ = close(current) }
    for component in relativePath.split(separator: "/").map(String.init) {
      if mkdirat(current, component, mode & 0o777) != 0, errno != EEXIST {
        throw CLIUsageError("unable to create detached workflow inventory directory")
      }
      let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard next >= 0 else {
        throw CLIUsageError("detached workflow inventory path contains an unsafe directory")
      }
      _ = close(current)
      current = next
    }
  }

  private func write(_ bytes: Data, to relativePath: String, mode: mode_t) throws {
    try validateRelativePath(relativePath)
    let parts = relativePath.split(separator: "/").map(String.init)
    guard let leaf = parts.last else { throw CLIUsageError("detached workflow inventory file is required") }
    let parentPath = parts.dropLast().joined(separator: "/")
    if !parentPath.isEmpty { try ensureDirectory(parentPath, mode: S_IRWXU) }
    let parent = parentPath.isEmpty ? dup(descriptor) : try openDirectory(parentPath)
    guard parent >= 0 else { throw CLIUsageError("unable to open detached workflow inventory parent") }
    defer { _ = close(parent) }
    let file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode & 0o777)
    guard file >= 0 else { throw CLIUsageError("unable to create detached workflow inventory file") }
    defer { _ = close(file) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        #if canImport(Darwin)
        let count = Darwin.write(file, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
        #else
        let count = Glibc.write(file, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
        #endif
        guard count > 0 else { throw CLIUsageError("unable to write detached workflow inventory file") }
        offset += count
      }
    }
    guard fsync(file) == 0 else { throw CLIUsageError("unable to sync detached workflow inventory file") }
  }

  private func inventory(
    descriptor source: Int32,
    prefix: String,
    entries: inout [WorkflowDetachedInventoryEntry]
  ) throws {
    for name in try names(descriptor: source) {
      var status = stat()
      guard fstatat(source, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw CLIUsageError("detached workflow entry disappeared during inventory")
      }
      let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
      switch status.st_mode & S_IFMT {
      case S_IFDIR:
        let child = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else {
          throw CLIUsageError("detached workflow directory is linked or inaccessible")
        }
        entries.append(WorkflowDetachedInventoryEntry(relativePath: relative, bytes: nil, mode: status.st_mode))
        do {
          try inventory(descriptor: child, prefix: relative, entries: &entries)
          _ = close(child)
        } catch {
          _ = close(child)
          throw error
        }
      case S_IFREG:
        let file = openat(source, name, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { throw CLIUsageError("detached workflow file is linked or inaccessible") }
        var opened = stat()
        guard fstat(file, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == status.st_dev,
              opened.st_ino == status.st_ino else {
          _ = close(file)
          throw CLIUsageError("detached workflow entry changed during inventory")
        }
        let bytes: Data
        do {
          bytes = try FileHandle(fileDescriptor: file, closeOnDealloc: false).readToEnd() ?? Data()
          _ = close(file)
        } catch {
          _ = close(file)
          throw error
        }
        entries.append(WorkflowDetachedInventoryEntry(relativePath: relative, bytes: bytes, mode: opened.st_mode))
      default:
        throw CLIUsageError("detached workflow inventory contains a linked or special entry")
      }
    }
  }

  private func names(descriptor source: Int32) throws -> [String] {
    let duplicate = openat(source, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { _ = close(duplicate) }
      throw CLIUsageError("unable to enumerate detached workflow directory")
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

  private func regularFileExists(_ name: String) throws -> Bool {
    try validateLeaf(name)
    var status = stat()
    if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return false }
      throw CLIUsageError("unable to inspect detached workflow stable marker")
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("detached workflow stable marker is linked or has unexpected type")
    }
    return true
  }

  private func readRegular(_ name: String) throws -> Data {
    try readRegular(parent: descriptor, name: name)
  }

  private func readRegular(parent: Int32, name: String) throws -> Data {
    let file = openat(parent, name, O_RDONLY | O_NOFOLLOW)
    guard file >= 0 else { throw CLIUsageError("unable to read detached workflow stable marker") }
    defer { _ = close(file) }
    var status = stat()
    guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("detached workflow stable marker changed type")
    }
    return try FileHandle(fileDescriptor: file, closeOnDealloc: false).readToEnd() ?? Data()
  }

  private func syncTree(descriptor source: Int32) throws {
    for name in try names(descriptor: source) {
      var status = stat()
      guard fstatat(source, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw CLIUsageError("detached workflow transaction entry disappeared during fsync")
      }
      switch status.st_mode & S_IFMT {
      case S_IFDIR:
        let child = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else {
          throw CLIUsageError("detached workflow transaction directory changed during fsync")
        }
        do {
          try syncTree(descriptor: child)
          _ = close(child)
        } catch {
          _ = close(child)
          throw error
        }
      case S_IFREG:
        let file = openat(source, name, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else {
          throw CLIUsageError("detached workflow transaction file changed during fsync")
        }
        let synchronized = fsync(file) == 0
        _ = close(file)
        guard synchronized else {
          throw CLIUsageError("unable to sync detached workflow transaction file")
        }
      default:
        throw CLIUsageError("detached workflow transaction tree contains a linked or special entry")
      }
    }
    guard fsync(source) == 0 else {
      throw CLIUsageError("unable to sync detached workflow transaction directory")
    }
  }

  func entryExists(_ name: String) throws -> Bool {
    try validateLeaf(name)
    var status = stat()
    if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return false }
      throw CLIUsageError("unable to inspect detached workflow transaction entry")
    }
    guard status.st_mode & S_IFMT != S_IFLNK else {
      throw CLIUsageError("detached workflow transaction entry is linked")
    }
    return true
  }

  private func validateRemovableTree(parent: Int32, leaf: String) throws {
    var status = stat()
    guard fstatat(parent, leaf, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw CLIUsageError("unable to inspect detached workflow transaction artifact")
    }
    guard status.st_mode & S_IFMT == S_IFDIR else {
      throw CLIUsageError("refusing to remove a linked or special detached workflow artifact")
    }
    let child = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard child >= 0 else { throw CLIUsageError("unable to open detached workflow transaction directory") }
    defer { _ = close(child) }
    for name in try names(descriptor: child) {
      var childStatus = stat()
      guard fstatat(child, name, &childStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw CLIUsageError("detached workflow transaction artifact disappeared")
      }
      if childStatus.st_mode & S_IFMT == S_IFDIR {
        try validateRemovableTree(parent: child, leaf: name)
      } else if childStatus.st_mode & S_IFMT != S_IFREG {
        throw CLIUsageError("refusing to remove a linked or special detached workflow artifact")
      }
    }
  }

  private func remove(parent: Int32, leaf: String) throws {
    var status = stat()
    guard fstatat(parent, leaf, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw CLIUsageError("unable to inspect detached workflow transaction artifact")
    }
    if status.st_mode & S_IFMT == S_IFREG {
      guard unlinkat(parent, leaf, 0) == 0 else {
        throw CLIUsageError("unable to remove detached workflow transaction file")
      }
      return
    }
    guard status.st_mode & S_IFMT == S_IFDIR else {
      throw CLIUsageError("refusing to remove a linked or special detached workflow artifact")
    }
    let child = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard child >= 0 else { throw CLIUsageError("unable to open detached workflow transaction directory") }
    var closed = false
    do {
      for name in try names(descriptor: child) { try remove(parent: child, leaf: name) }
      guard fsync(child) == 0 else { throw CLIUsageError("unable to sync detached workflow transaction directory") }
      _ = close(child)
      closed = true
      guard unlinkat(parent, leaf, AT_REMOVEDIR) == 0 else {
        throw CLIUsageError("unable to remove detached workflow transaction directory")
      }
    } catch {
      if !closed { _ = close(child) }
      throw error
    }
  }

  private func validateLeaf(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      throw CLIUsageError("detached workflow transaction entry has an unsafe name")
    }
  }

  private func validateRelativePath(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/") else {
      throw CLIUsageError("detached workflow path must be relative")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
      throw CLIUsageError("detached workflow path contains an unsafe component")
    }
  }
}
