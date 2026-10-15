import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct NativeAddonBridgeRequest: Codable {
  var version = 1
  var id: UUID
  var arguments: [String]
  var deadline: Date
}

struct NativeAddonBridgeReply: Codable {
  var output: AppleGatewayProcessOutput?
  var failure: BuiltinAddonContainerFailure?

  func validatedOutput() throws -> AppleGatewayProcessOutput {
    if let failure {
      guard output == nil else { throw AdapterExecutionError(.invalidOutput, "contradictory native bridge reply") }
      throw try failure.executionError()
    }
    guard let output else { throw AdapterExecutionError(.invalidOutput, "native bridge output is missing") }
    return output
  }
}

/// A pinned directory descriptor prevents guest-created symlinks and directory
/// renames from redirecting the host's RPC reads and writes.
final class NativeAddonBridgeChannel: @unchecked Sendable {
  let directory: URL
  private let descriptor: Int32
  private let parentDescriptor: Int32?
  private let parentEntry: String?
  private static let maximumEntries = 512

  init(directory: URL) throws {
    self.directory = directory
    parentDescriptor = nil
    parentEntry = nil
    descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw AdapterExecutionError(.policyBlocked, "native bridge directory is unavailable") }
  }

  private init(directory: URL, descriptor: Int32, parentDescriptor: Int32, parentEntry: String) {
    self.directory = directory
    self.descriptor = descriptor
    self.parentDescriptor = parentDescriptor
    self.parentEntry = parentEntry
  }

  static func create(workingDirectory: URL) throws -> NativeAddonBridgeChannel {
    var parent = open(workingDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw AdapterExecutionError(.policyBlocked, "native bridge workspace is unavailable") }
    var directory = workingDirectory
    do {
      for component in [".riela", "addon-container-state", "bridges"] {
        let next = try openOrCreateGitFinalizationDirectory(in: parent, name: component)
        close(parent)
        parent = next
        directory.appendPathComponent(component, isDirectory: true)
      }
      let entry = UUID().uuidString
      let child = try openOrCreateGitFinalizationDirectory(in: parent, name: entry)
      return NativeAddonBridgeChannel(directory: directory.appendingPathComponent(entry, isDirectory: true),
        descriptor: child, parentDescriptor: parent, parentEntry: entry)
    } catch {
      close(parent)
      throw error
    }
  }

  deinit {
    if let parentDescriptor, let parentEntry {
      // All deletion uses pinned descriptors. Never recursively follow a
      // pathname that a guest could replace with a symlink or another folder.
      if let entries = try? boundedGitFinalizationDirectoryEntries(directoryDescriptor: descriptor,
        directoryURL: directory, maximumEntries: Self.maximumEntries, includingHidden: true) {
        for entry in entries { _ = unlinkat(descriptor, entry.lastPathComponent, 0) }
      }
      var owned = stat()
      var current = stat()
      if fstat(descriptor, &owned) == 0,
         fstatat(parentDescriptor, parentEntry, &current, AT_SYMLINK_NOFOLLOW) == 0,
         owned.st_dev == current.st_dev, owned.st_ino == current.st_ino {
        _ = unlinkat(parentDescriptor, parentEntry, AT_REMOVEDIR)
      }
      close(parentDescriptor)
    }
    close(descriptor)
  }

  func requests() throws -> [UUID] {
    try boundedGitFinalizationDirectoryEntries(directoryDescriptor: descriptor, directoryURL: directory,
      maximumEntries: Self.maximumEntries).compactMap { url in
        guard url.pathExtension == "request" else { return nil }
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
          throw AdapterExecutionError(.policyBlocked, "invalid native bridge request filename")
        }
        return id
      }
  }

  func request(_ id: UUID) throws -> NativeAddonBridgeRequest {
    let request: NativeAddonBridgeRequest = try read(name: name(id, suffix: "request"), maximumBytes: BuiltinAddonContainerRequest.maximumRecordBytes)
    guard request.version == 1, request.id == id else {
      throw AdapterExecutionError(.policyBlocked, "invalid native bridge request identity")
    }
    return request
  }

  func reply(_ reply: NativeAddonBridgeReply, to id: UUID) throws {
    try write(reply, name: name(id, suffix: "reply"))
  }

  func call(arguments: [String], deadline: Date?) throws -> AppleGatewayProcessOutput {
    let request = NativeAddonBridgeRequest(id: UUID(), arguments: arguments, deadline: deadline ?? Date().addingTimeInterval(120))
    try write(request, name: name(request.id, suffix: "request"))
    defer {
      _ = unlinkat(descriptor, name(request.id, suffix: "request"), 0)
      _ = unlinkat(descriptor, name(request.id, suffix: "reply"), 0)
    }
    while Date() < request.deadline {
      var status = stat()
      if fstatat(descriptor, name(request.id, suffix: "reply"), &status, AT_SYMLINK_NOFOLLOW) == 0 {
        let reply: NativeAddonBridgeReply = try read(name: name(request.id, suffix: "reply"),
          maximumBytes: BuiltinAddonContainerRequest.maximumRecordBytes)
        return try reply.validatedOutput()
      }
      guard errno == ENOENT else { throw AdapterExecutionError(.policyBlocked, "native bridge reply is inaccessible") }
      Thread.sleep(forTimeInterval: 0.01)
    }
    throw AdapterExecutionError(.timeout, "native bridge request exceeded its deadline")
  }

  private func name(_ id: UUID, suffix: String) -> String { id.uuidString + "." + suffix }

  private func read<Value: Decodable>(name: String, maximumBytes: Int) throws -> Value {
    let data = try boundedGitFinalizationRecordData(directoryDescriptor: descriptor, name: name, maxBytes: maximumBytes)
    return try JSONDecoder().decode(Value.self, from: data)
  }

  private func write<Value: Encodable>(_ value: Value, name: String) throws {
    let data = try JSONEncoder().encode(value)
    guard data.count <= BuiltinAddonContainerRequest.maximumRecordBytes else {
      throw AdapterExecutionError(.invalidOutput, "native bridge record exceeds its size limit")
    }
    let temporary = UUID().uuidString + ".tmp"
    let file = try createGitFinalizationFile(in: descriptor, name: temporary, data: data)
    close(file)
    defer { _ = unlinkat(descriptor, temporary, 0) }
    guard renameat(descriptor, temporary, descriptor, name) == 0 else {
      throw AdapterExecutionError(.providerError, "native bridge record publication failed")
    }
  }
}
