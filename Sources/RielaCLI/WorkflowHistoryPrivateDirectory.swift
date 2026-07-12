import Darwin
import Foundation
import RielaCore

enum WorkflowHistoryConstructionBoundary: Equatable, Sendable {
  case childDirectory
  case leafFile
  case beforeVerification
}

/// A private history artifact whose parent and root directory identities remain
/// pinned from creation through publication. Every child operation is relative
/// to the retained artifact descriptor and rejects links and special files.
final class WorkflowHistoryPrivateDirectory {
  let url: URL
  private let parentDescriptor: Int32
  private let descriptor: Int32
  private let leaf: String
  private var published = false

  init(parent: URL, pinnedRoot: WorkflowHistoryPinnedRoot) throws {
    try pinnedRoot.ensureDirectory(parent)
    parentDescriptor = try pinnedRoot.openDirectory(pinnedRoot.relativePath(for: parent))
    leaf = ".tmp-\(UUID().uuidString.lowercased())"
    guard mkdirat(parentDescriptor, leaf, S_IRWXU) == 0 else {
      _ = close(parentDescriptor)
      throw CLIUsageError("unable to create private workflow history artifact")
    }
    descriptor = openat(parentDescriptor, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      _ = unlinkat(parentDescriptor, leaf, AT_REMOVEDIR)
      _ = close(parentDescriptor)
      throw CLIUsageError("unable to pin private workflow history artifact")
    }
    url = parent.appendingPathComponent(leaf, isDirectory: true)
  }

  deinit {
    if !published { try? remove() }
    _ = close(descriptor)
    _ = close(parentDescriptor)
  }

  func ensureDirectory(_ relative: String) throws {
    let directory = try openDirectory(relative, create: true)
    _ = close(directory)
  }

  func write(_ bytes: Data, to relative: String) throws {
    let (parent, name) = try openParent(relative, create: true)
    defer { _ = close(parent) }
    let file = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard file >= 0 else { throw CLIUsageError("unable to create private workflow history file") }
    defer { _ = close(file) }
    try bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        guard let base = raw.baseAddress else { return }
        let count = Darwin.write(file, base.advanced(by: offset), raw.count - offset)
        guard count > 0 else { throw CLIUsageError("unable to write private workflow history file") }
        offset += count
      }
    }
    guard fsync(file) == 0 else { throw CLIUsageError("unable to fsync private workflow history file") }
  }

  func read(_ relative: String, requireNonWritable: Bool = false) throws -> Data {
    let (parent, name) = try openParent(relative)
    defer { _ = close(parent) }
    let file = openat(parent, name, O_RDONLY | O_NOFOLLOW)
    guard file >= 0 else { throw CLIUsageError("unable to read private workflow history file") }
    defer { _ = close(file) }
    var status = stat()
    guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
          !requireNonWritable || status.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0 else {
      throw CLIUsageError("private workflow history file changed type or permissions")
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(file, &buffer, buffer.count)
      guard count >= 0 else { throw CLIUsageError("unable to read private workflow history file") }
      if count == 0 { break }
      result.append(buffer, count: count)
    }
    return result
  }

  func entryExists(_ relative: String) throws -> Bool {
    try WorkflowHistoryCanonicalCoding.validateRelativePath(relative)
    let parts = relative.split(separator: "/").map(String.init)
    guard let name = parts.last else { return false }
    var parent = dup(descriptor)
    guard parent >= 0 else { throw CLIUsageError("unable to duplicate private artifact descriptor") }
    defer { _ = close(parent) }
    for component in parts.dropLast() {
      let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      if next < 0, errno == ENOENT { return false }
      guard next >= 0 else { throw CLIUsageError("private workflow history directory changed type") }
      _ = close(parent)
      parent = next
    }
    var status = stat()
    if fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return false }
      throw CLIUsageError("unable to inspect private workflow history entry")
    }
    guard status.st_mode & S_IFMT != S_IFLNK else {
      throw CLIUsageError("private workflow history entry is a symbolic link")
    }
    return true
  }

  func verifyTopology(files: Set<String>, directories: Set<String>, requireNonWritable: Bool) throws {
    var actualFiles: Set<String> = []
    var actualDirectories: Set<String> = []
    try enumerate(descriptor: descriptor, prefix: "", requireNonWritable: requireNonWritable) { path, type in
      if type == S_IFDIR { actualDirectories.insert(path) } else { actualFiles.insert(path) }
    }
    guard actualFiles == files, actualDirectories == directories else {
      throw CLIUsageError("private workflow history artifact has noncanonical topology")
    }
  }

  func syncAndMakeImmutable() throws {
    try transformTree(descriptor: descriptor)
  }

  func publish(to destination: URL, pinnedRoot: WorkflowHistoryPinnedRoot) throws {
    let destinationParent = destination.deletingLastPathComponent()
    guard destinationParent.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL else {
      throw CLIUsageError("private workflow history publication requires sibling directories")
    }
    var sourceStatus = stat()
    var pinnedStatus = stat()
    guard fstatat(parentDescriptor, leaf, &sourceStatus, AT_SYMLINK_NOFOLLOW) == 0,
          fstat(descriptor, &pinnedStatus) == 0,
          sourceStatus.st_mode & S_IFMT == S_IFDIR,
          sourceStatus.st_dev == pinnedStatus.st_dev,
          sourceStatus.st_ino == pinnedStatus.st_ino else {
      throw CLIUsageError("private workflow history artifact identity changed before publication")
    }
    let target = destination.lastPathComponent
    let result = leaf.withCString { source in
      target.withCString { destinationName in
        renameatx_np(parentDescriptor, source, parentDescriptor, destinationName, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0 else {
      if errno == EEXIST { throw CLIUsageError("immutable workflow history id already exists: \(target)") }
      throw CLIUsageError("unable to publish private workflow history artifact")
    }
    guard fsync(parentDescriptor) == 0 else {
      throw CLIUsageError("unable to fsync workflow history publication directory")
    }
    published = true
  }

  func remove() throws {
    try makeMutableAndRemoveContents(descriptor)
    guard unlinkat(parentDescriptor, leaf, AT_REMOVEDIR) == 0 || errno == ENOENT else {
      throw CLIUsageError("unable to remove private workflow history artifact")
    }
    guard fsync(parentDescriptor) == 0 else {
      throw CLIUsageError("unable to fsync private workflow history artifact removal")
    }
  }

  private func openDirectory(_ relative: String, create: Bool = false) throws -> Int32 {
    if relative.isEmpty { return dup(descriptor) }
    try WorkflowHistoryCanonicalCoding.validateRelativePath(relative)
    var current = dup(descriptor)
    guard current >= 0 else { throw CLIUsageError("unable to duplicate private artifact descriptor") }
    do {
      for component in relative.split(separator: "/").map(String.init) {
        if create, mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
          throw CLIUsageError("unable to create private workflow history directory")
        }
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard next >= 0 else {
          throw CLIUsageError("private workflow history directory changed type at \(component) (errno \(errno))")
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

  private func openParent(_ relative: String, create: Bool = false) throws -> (Int32, String) {
    try WorkflowHistoryCanonicalCoding.validateRelativePath(relative)
    let parts = relative.split(separator: "/").map(String.init)
    guard let name = parts.last else { throw CLIUsageError("private workflow history file name is required") }
    return (try openDirectory(parts.dropLast().joined(separator: "/"), create: create), name)
  }

  private func enumerate(
    descriptor source: Int32,
    prefix: String,
    requireNonWritable: Bool,
    visit: (String, mode_t) throws -> Void
  ) throws {
    let duplicate = dup(source)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { _ = close(duplicate) }
      throw CLIUsageError("unable to enumerate private workflow history artifact")
    }
    defer { closedir(directory) }
    // `dup` shares the open file description (and its read offset) with `source`.
    // If `source` has already been read to EOF, this stream would otherwise see no
    // entries; rewind so enumeration always starts at the beginning.
    rewinddir(directory)
    var names: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != ".", name != ".." { names.append(name) }
    }
    for name in names.sorted() {
      var status = stat()
      guard fstatat(source, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw CLIUsageError("private workflow history entry disappeared during enumeration")
      }
      let type = status.st_mode & S_IFMT
      guard type == S_IFDIR || type == S_IFREG,
            !requireNonWritable || status.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0 else {
        throw CLIUsageError("private workflow history entry has unsafe type or permissions")
      }
      let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
      try visit(path, type)
      if type == S_IFDIR {
        let child = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else {
          throw CLIUsageError("private workflow history directory changed type at \(path) (errno \(errno))")
        }
        defer { _ = close(child) }
        try enumerate(descriptor: child, prefix: path, requireNonWritable: requireNonWritable, visit: visit)
      }
    }
  }

  private func transformTree(descriptor source: Int32) throws {
    try forEachChild(of: source) { child, type in
      if type == S_IFDIR { try transformTree(descriptor: child) }
      guard fsync(child) == 0,
            fchmod(child, type == S_IFDIR ? 0o555 : 0o444) == 0,
            fsync(child) == 0 else {
        throw CLIUsageError("unable to durably make private workflow history artifact immutable")
      }
    }
    guard fsync(source) == 0, fchmod(source, 0o555) == 0, fsync(source) == 0 else {
      throw CLIUsageError("unable to durably make private workflow history directory immutable")
    }
  }

  private func makeMutableAndRemoveContents(_ source: Int32) throws {
    _ = fchmod(source, S_IRWXU)
    let names = try childNames(source)
    for name in names {
      var status = stat()
      guard fstatat(source, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
      let type = status.st_mode & S_IFMT
      if type == S_IFDIR {
        let child = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else { throw CLIUsageError("private artifact cleanup encountered changed directory") }
        try makeMutableAndRemoveContents(child)
        _ = close(child)
        guard unlinkat(source, name, AT_REMOVEDIR) == 0 else {
          throw CLIUsageError("unable to remove private workflow history directory")
        }
      } else {
        guard type == S_IFREG, unlinkat(source, name, 0) == 0 else {
          throw CLIUsageError("private artifact cleanup encountered unsafe entry")
        }
      }
    }
    guard fsync(source) == 0 else { throw CLIUsageError("unable to fsync private artifact cleanup") }
  }

  private func forEachChild(of source: Int32, body: (Int32, mode_t) throws -> Void) throws {
    for name in try childNames(source) {
      var status = stat()
      guard fstatat(source, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw CLIUsageError("private workflow history entry changed during traversal")
      }
      let type = status.st_mode & S_IFMT
      let flags = type == S_IFDIR ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW : O_RDONLY | O_NOFOLLOW
      guard type == S_IFDIR || type == S_IFREG else {
        throw CLIUsageError("private workflow history artifact contains a special entry")
      }
      let child = openat(source, name, flags)
      guard child >= 0 else { throw CLIUsageError("private workflow history entry changed type") }
      defer { _ = close(child) }
      try body(child, type)
    }
  }

  private func childNames(_ source: Int32) throws -> [String] {
    let duplicate = dup(source)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { _ = close(duplicate) }
      throw CLIUsageError("unable to enumerate private workflow history directory")
    }
    defer { closedir(directory) }
    // `dup` shares the open file description (and its read offset) with `source`.
    // If `source` has already been read to EOF, this stream would otherwise see no
    // entries; rewind so enumeration always starts at the beginning.
    rewinddir(directory)
    var names: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != ".", name != ".." { names.append(name) }
    }
    return names.sorted()
  }
}
