import Foundation
import RielaCore
import RielaWork

struct FileHandoverSink: HandoverSink {
  let root: URL
  let kind: HandoverSinkKind = .file

  init(root: String) {
    self.root = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
  }

  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef {
    guard safeComponent(packet.taskId.rawValue), safeComponent(packet.id.rawValue) else {
      throw HandoverSinkError.invalidConfiguration("file sink task and handover ids must be path components")
    }
    let directory = root.appendingPathComponent("handovers", isDirectory: true)
      .appendingPathComponent(packet.taskId.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let jsonURL = directory.appendingPathComponent(packet.id.rawValue + ".json")
    let markdownURL = directory.appendingPathComponent(packet.id.rawValue + ".md")
    if FileManager.default.fileExists(atPath: jsonURL.path) {
      guard try Data(contentsOf: jsonURL) == bytes else {
        throw HandoverSinkError.conflictingContent(jsonURL.path)
      }
    } else {
      try atomicallyWrite(bytes, to: jsonURL)
    }
    try atomicallyWrite(Data(brief.utf8), to: markdownURL, replacing: true)
    return HandoverSinkRef(kind: kind, locator: jsonURL.path, digest: packet.digest, writtenAt: Date())
  }

  func read(_ ref: HandoverSinkRef) async throws -> Data {
    guard ref.kind == kind, ref.locator.hasPrefix("/") else {
      throw HandoverSinkError.invalidLocator(ref.locator)
    }
    return try Data(contentsOf: URL(fileURLWithPath: ref.locator))
  }

  private func atomicallyWrite(_ data: Data, to target: URL, replacing: Bool = false) throws {
    let temporary = target.deletingLastPathComponent()
      .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporary, options: .withoutOverwriting)
      if replacing {
        guard rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      } else {
        try FileManager.default.moveItem(at: temporary, to: target)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private func safeComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
  }
}
