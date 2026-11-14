#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

/// Pins the selected history root and resolves every child through directory
/// descriptors. Absolute path validation alone is insufficient because an
/// ancestor may be exchanged after validation.
final class WorkflowHistoryPinnedRoot: @unchecked Sendable {
  let url: URL
  let descriptor: Int32

  init(_ root: URL, create: Bool = true) throws {
    url = try Self.canonicalPotentialPath(root)
    guard url.path.hasPrefix("/") else {
      throw CLIUsageError("workflow history root must be absolute")
    }
    var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard current >= 0 else { throw CLIUsageError("unable to pin filesystem root") }
    do {
      for component in url.pathComponents.dropFirst() where component != "/" {
        if create, mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
          throw CLIUsageError("unable to create workflow history root component")
        }
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard next >= 0 else {
          throw CLIUsageError(
            "workflow history root contains a linked or non-directory component: \(component) in \(url.path) (errno \(errno))"
          )
        }
        var status = stat()
        guard fstat(next, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
          _ = close(next)
          throw CLIUsageError("workflow history root component changed type")
        }
        _ = close(current)
        current = next
      }
      descriptor = current
    } catch {
      _ = close(current)
      throw error
    }
  }

  deinit { _ = close(descriptor) }

  func relativePath(for child: URL) throws -> String {
    let standardized = child.standardizedFileURL
    let candidate: String
    if standardized.path.hasPrefix(url.path + "/") || standardized.path == url.path {
      candidate = standardized.path
    } else {
      // The child is spelled through a different (symlinked) ancestor of the
      // root. Canonicalize only the root-prefix portion and keep every
      // component below the root verbatim: resolving the full path here
      // (realpath) would silently follow a swapped child symlink before the
      // O_NOFOLLOW descriptor walk could reject it.
      candidate = try Self.rootAnchoredPath(standardized, canonicalRoot: url.path)
    }
    guard candidate != url.path, candidate.hasPrefix(url.path + "/") else {
      if candidate == url.path { return "" }
      throw CLIUsageError("workflow history path escapes selected root")
    }
    let relative = String(candidate.dropFirst(url.path.count + 1))
    try WorkflowHistoryCanonicalCoding.validateRelativePath(relative)
    return relative
  }

  func ensureDirectory(_ child: URL) throws {
    let relative = try relativePath(for: child)
    let opened = try openDirectory(relative, create: true)
    _ = close(opened)
  }

  func openDirectory(_ relative: String, create: Bool = false) throws -> Int32 {
    if relative.isEmpty { return dup(descriptor) }
    try WorkflowHistoryCanonicalCoding.validateRelativePath(relative)
    var current = dup(descriptor)
    guard current >= 0 else { throw CLIUsageError("unable to duplicate pinned history root") }
    do {
      for component in relative.split(separator: "/").map(String.init) {
        if create, mkdirat(current, component, S_IRWXU) != 0, errno != EEXIST {
          throw CLIUsageError("unable to create workflow history directory")
        }
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard next >= 0 else {
          throw CLIUsageError("workflow history directory contains a linked or non-directory component")
        }
        var status = stat()
        guard fstat(next, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
          _ = close(next)
          throw CLIUsageError("workflow history directory changed type")
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

  func withParent<T>(of child: URL, create: Bool = false, _ body: (Int32, String) throws -> T) throws -> T {
    let relative = try relativePath(for: child)
    let components = relative.split(separator: "/").map(String.init)
    guard let leaf = components.last else { throw CLIUsageError("workflow history leaf is required") }
    let parent = components.dropLast().joined(separator: "/")
    let parentDescriptor = try openDirectory(parent, create: create)
    defer { _ = close(parentDescriptor) }
    return try body(parentDescriptor, leaf)
  }

  func readRegular(_ child: URL, requireNonWritable: Bool = false) throws -> Data {
    try withParent(of: child) { parent, leaf in
      let file = openat(parent, leaf, O_RDONLY | O_NOFOLLOW)
      guard file >= 0 else { throw CLIUsageError("unable to open workflow history record without following links") }
      defer { _ = close(file) }
      var status = stat()
      guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
        throw CLIUsageError("workflow history record changed type")
      }
      if requireNonWritable, status.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) != 0 {
        throw CLIUsageError("workflow history record is writable: \(child.path)")
      }
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 16_384)
      while true {
        #if canImport(Darwin)
        let count = Darwin.read(file, &buffer, buffer.count)
        #else
        let count = Glibc.read(file, &buffer, buffer.count)
        #endif
        guard count >= 0 else { throw CLIUsageError("unable to read workflow history record") }
        if count == 0 { break }
        bytes.append(buffer, count: count)
      }
      return bytes
    }
  }

  func requireDirectoryNonWritable(_ child: URL) throws {
    let relative = try relativePath(for: child)
    let directory = try openDirectory(relative)
    defer { _ = close(directory) }
    var status = stat()
    guard fstat(directory, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR,
          status.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0 else {
      throw CLIUsageError("workflow history directory is writable or changed type: \(child.path)")
    }
  }

  func setPermissions(_ permissions: mode_t, for child: URL, expectedType: mode_t) throws {
    try withParent(of: child) { parent, leaf in
      let flags = expectedType == S_IFDIR ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW : O_RDONLY | O_NOFOLLOW
      let descriptor = openat(parent, leaf, flags)
      guard descriptor >= 0 else { throw CLIUsageError("unable to open workflow history entry for chmod") }
      defer { _ = close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == expectedType else {
        throw CLIUsageError("workflow history entry changed type before chmod")
      }
      guard fchmod(descriptor, permissions) == 0, fsync(descriptor) == 0 else {
        throw CLIUsageError("unable to make workflow history entry immutable")
      }
    }
  }

  func entryType(_ child: URL) throws -> mode_t? {
    try withParent(of: child) { parent, leaf in
      var status = stat()
      if fstatat(parent, leaf, &status, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno == ENOENT { return nil }
        throw CLIUsageError("unable to inspect workflow history entry")
      }
      guard status.st_mode & S_IFMT != S_IFLNK else {
        throw CLIUsageError("workflow history entry is a symbolic link")
      }
      return status.st_mode & S_IFMT
    }
  }

  func atomicWrite(_ bytes: Data, to child: URL, overwrite: Bool) throws {
    try withParent(of: child, create: true) { parent, leaf in
      let temporary = ".tmp-\(UUID().uuidString.lowercased())"
      let file = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
      guard file >= 0 else { throw CLIUsageError("unable to create workflow history temporary file") }
      var closed = false
      defer {
        if !closed { _ = close(file) }
        _ = unlinkat(parent, temporary, 0)
      }
      try Self.writeAll(bytes, descriptor: file)
      guard fsync(file) == 0, close(file) == 0 else {
        closed = true
        throw CLIUsageError("unable to durably close workflow history record")
      }
      closed = true
      let result = temporary.withCString { source in
        leaf.withCString { destination in
          overwrite
            ? renameat(parent, source, parent, destination)
            : workflowHistoryExclusiveRename(
              oldDirectory: parent,
              oldName: source,
              newDirectory: parent,
              newName: destination
            )
        }
      }
      guard result == 0 else {
        if !overwrite, errno == EEXIST {
          throw CLIUsageError("immutable workflow history record already exists: \(leaf)")
        }
        throw CLIUsageError("unable to publish workflow history record")
      }
      guard fsync(parent) == 0 else { throw CLIUsageError("unable to fsync workflow history directory") }
    }
  }

  func unlink(_ child: URL, directory: Bool = false) throws {
    try withParent(of: child) { parent, leaf in
      guard unlinkat(parent, leaf, directory ? AT_REMOVEDIR : 0) == 0 else {
        if errno == ENOENT { return }
        throw CLIUsageError("unable to remove workflow history entry")
      }
      guard fsync(parent) == 0 else { throw CLIUsageError("unable to fsync workflow history directory") }
    }
  }

  func publishDirectory(_ temporary: URL, to destination: URL) throws {
    let temporaryRelative = try relativePath(for: temporary)
    let destinationRelative = try relativePath(for: destination)
    let temporaryParts = temporaryRelative.split(separator: "/").map(String.init)
    let destinationParts = destinationRelative.split(separator: "/").map(String.init)
    guard temporaryParts.dropLast() == destinationParts.dropLast(),
          let source = temporaryParts.last, let target = destinationParts.last else {
      throw CLIUsageError("immutable workflow history publication requires sibling directories")
    }
    let parent = try openDirectory(temporaryParts.dropLast().joined(separator: "/"))
    defer { _ = close(parent) }
    let result = source.withCString { sourceName in
      target.withCString { targetName in
        workflowHistoryExclusiveRename(
          oldDirectory: parent,
          oldName: sourceName,
          newDirectory: parent,
          newName: targetName
        )
      }
    }
    guard result == 0 else {
      if errno == EEXIST { throw CLIUsageError("immutable workflow history id already exists: \(target)") }
      throw CLIUsageError("unable to exclusively publish immutable workflow history directory")
    }
    guard fsync(parent) == 0 else { throw CLIUsageError("unable to fsync workflow history publication directory") }
  }

  func names(in child: URL) throws -> [String] {
    let relative = try relativePath(for: child)
    let directoryDescriptor = try openDirectory(relative)
    guard let directory = fdopendir(directoryDescriptor) else {
      _ = close(directoryDescriptor)
      throw CLIUsageError("unable to enumerate pinned workflow history directory")
    }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != ".", name != ".." { names.append(name) }
    }
    return names.sorted()
  }

  private static func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        guard let base = raw.baseAddress else { return }
        #if canImport(Darwin)
        let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
        #else
        let count = Glibc.write(descriptor, base.advanced(by: offset), raw.count - offset)
        #endif
        guard count > 0 else { throw CLIUsageError("unable to write workflow history record") }
        offset += count
      }
    }
  }

  /// Finds the ancestor of `input` whose canonical path is the pinned root
  /// and re-anchors the remaining components verbatim. Components below the
  /// root are never symlink-resolved — the descriptor walk verifies each of
  /// them with O_NOFOLLOW instead.
  private static func rootAnchoredPath(_ input: URL, canonicalRoot: String) throws -> String {
    var prefix = input
    var suffix: [String] = []
    while true {
      if let resolvedPointer = realpath(prefix.path, nil) {
        let resolved = String(cString: resolvedPointer)
        free(resolvedPointer)
        if resolved == canonicalRoot {
          guard !suffix.isEmpty else {
            return canonicalRoot
          }
          return canonicalRoot + "/" + suffix.reversed().joined(separator: "/")
        }
      }
      if prefix.path == "/" {
        break
      }
      suffix.append(prefix.lastPathComponent)
      prefix.deleteLastPathComponent()
    }
    throw CLIUsageError("workflow history path escapes selected root")
  }

  private static func canonicalPotentialPath(_ input: URL) throws -> URL {
    var existing = input.standardizedFileURL
    var suffix: [String] = []
    var status = stat()
    while lstat(existing.path, &status) != 0, existing.path != "/" {
      suffix.append(existing.lastPathComponent)
      existing.deleteLastPathComponent()
    }
    guard let resolvedPointer = realpath(existing.path, nil) else {
      throw CLIUsageError("unable to canonicalize workflow history root")
    }
    defer { free(resolvedPointer) }
    let resolved = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
    return suffix.reversed().reduce(resolved) { $0.appendingPathComponent($1, isDirectory: true) }
  }
}
