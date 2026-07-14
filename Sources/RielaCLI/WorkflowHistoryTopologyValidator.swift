#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

enum WorkflowHistoryTopologyValidator {
  static func canonicalDirectories(forFiles files: Set<String>, required: Set<String> = []) -> Set<String> {
    files.reduce(into: required) { result, file in
      var components = file.split(separator: "/").map(String.init)
      _ = components.popLast()
      while !components.isEmpty {
        result.insert(components.joined(separator: "/"))
        _ = components.popLast()
      }
    }
  }

  static func validate(
    directory: URL,
    historyRoot: URL,
    expectedFiles: Set<String>,
    expectedDirectories: Set<String>,
    requireNonWritable: Bool
  ) throws {
    let pinned = try WorkflowHistoryPinnedRoot(historyRoot, create: false)
    let relative = try pinned.relativePath(for: directory)
    let descriptor = try pinned.openDirectory(relative)
    defer { _ = close(descriptor) }
    var files = Set<String>()
    var directories = Set<String>()
    try enumerate(
      descriptor: descriptor,
      relativePrefix: "",
      displayRoot: directory.path,
      files: &files,
      directories: &directories,
      requireNonWritable: requireNonWritable
    )
    if requireNonWritable { try requireNonWritableDirectory(descriptor, path: directory.path) }
    guard files == expectedFiles, directories == expectedDirectories else {
      throw CLIUsageError(
        "workflow history artifact topology is noncanonical; "
          + "files=\(files.sorted()) directories=\(directories.sorted())"
      )
    }
  }

  private static func enumerate(
    descriptor: Int32,
    relativePrefix: String,
    displayRoot: String,
    files: inout Set<String>,
    directories: inout Set<String>,
    requireNonWritable: Bool
  ) throws {
    let duplicate = dup(descriptor)
    guard duplicate >= 0, let stream = fdopendir(duplicate) else {
      if duplicate >= 0 { _ = close(duplicate) }
      throw CLIUsageError("unable to descriptor-enumerate workflow history topology")
    }
    defer { closedir(stream) }
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      guard name != ".", name != ".." else { continue }
      var status = stat()
      guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw CLIUsageError("unable to inspect workflow history topology entry")
      }
      let relative = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
      switch status.st_mode & S_IFMT {
      case S_IFREG:
        if requireNonWritable, status.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) != 0 {
          throw CLIUsageError("workflow history artifact is writable: \(displayRoot)/\(relative)")
        }
        files.insert(relative)
      case S_IFDIR:
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else { throw CLIUsageError("workflow history directory changed during enumeration") }
        do {
          if requireNonWritable { try requireNonWritableDirectory(child, path: "\(displayRoot)/\(relative)") }
          directories.insert(relative)
          try enumerate(
            descriptor: child,
            relativePrefix: relative,
            displayRoot: displayRoot,
            files: &files,
            directories: &directories,
            requireNonWritable: requireNonWritable
          )
          _ = close(child)
        } catch {
          _ = close(child)
          throw error
        }
      case S_IFLNK:
        throw CLIUsageError("workflow history artifact contains a link: \(relative)")
      default:
        throw CLIUsageError("workflow history artifact contains a special file: \(relative)")
      }
    }
  }

  private static func requireNonWritableDirectory(_ descriptor: Int32, path: String) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR,
          status.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0 else {
      throw CLIUsageError("workflow history directory is writable or changed type: \(path)")
    }
  }
}
