import Foundation

public enum AgentRolloutWatcherEvent<RolloutLine>: Sendable where RolloutLine: Sendable {
  case line(path: String, line: RolloutLine)
  case newSession(path: String)
  case error(path: String?, message: String)
}

extension AgentRolloutWatcherEvent: Equatable where RolloutLine: Equatable {}

public final class AgentRolloutWatcher<RolloutLine>: @unchecked Sendable where RolloutLine: Sendable {
  public typealias RolloutLineParser = @Sendable (String) -> RolloutLine?

  private let lock = NSLock()
  private let rolloutLineParser: RolloutLineParser
  private var fileOffsets: [String: UInt64] = [:]
  private var sessionDirectories: Set<String> = []
  private var knownSessionFiles: Set<String> = []
  private var closed = false

  public init(rolloutLineParser: @escaping RolloutLineParser) {
    self.rolloutLineParser = rolloutLineParser
  }

  public var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  public func watchFile(path: String, startOffset: UInt64? = nil) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, fileOffsets[path] == nil else {
      return
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
    fileOffsets[path] = startOffset ?? size
  }

  public func watchSessionsDirectory(path: String) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else {
      return
    }
    sessionDirectories.insert(path)
    for rolloutPath in Self.rolloutFilesRecursively(root: path) {
      knownSessionFiles.insert(rolloutPath)
    }
  }

  public func flush() -> [AgentRolloutWatcherEvent<RolloutLine>] {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return []
    }
    let watchedFiles = fileOffsets
    let watchedDirectories = Array(sessionDirectories)
    lock.unlock()

    var events: [AgentRolloutWatcherEvent<RolloutLine>] = []
    for directory in watchedDirectories {
      events.append(contentsOf: flushNewSessionEvents(in: directory))
    }
    for (path, offset) in watchedFiles {
      events.append(contentsOf: flushFileEvents(path: path, offset: offset))
    }
    return events
  }

  public func stop() {
    lock.lock()
    closed = true
    fileOffsets = [:]
    sessionDirectories = []
    knownSessionFiles = []
    lock.unlock()
  }

  public static func rolloutFilesRecursively(root: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
      at: URL(fileURLWithPath: root, isDirectory: true),
      includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
      return []
    }
    return enumerator.compactMap { entry -> String? in
      guard let url = entry as? URL else {
        return nil
      }
      guard url.lastPathComponent.hasPrefix("rollout-"), url.lastPathComponent.hasSuffix(".jsonl") else {
        return nil
      }
      return url.path
    }.sorted()
  }

  private func flushNewSessionEvents(in directory: String) -> [AgentRolloutWatcherEvent<RolloutLine>] {
    var events: [AgentRolloutWatcherEvent<RolloutLine>] = []
    for rolloutPath in Self.rolloutFilesRecursively(root: directory) {
      lock.lock()
      let isNew = !knownSessionFiles.contains(rolloutPath)
      if isNew {
        knownSessionFiles.insert(rolloutPath)
      }
      lock.unlock()
      if isNew {
        events.append(.newSession(path: rolloutPath))
      }
    }
    return events
  }

  private func flushFileEvents(path: String, offset: UInt64) -> [AgentRolloutWatcherEvent<RolloutLine>] {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
      return [.error(path: path, message: "rollout file is not readable")]
    }
    guard UInt64(data.count) >= offset else {
      updateOffset(path: path, offset: UInt64(data.count))
      return []
    }

    var events: [AgentRolloutWatcherEvent<RolloutLine>] = []
    let appended = data.dropFirst(Int(offset))
    var nextOffset = offset
    if let text = String(data: appended, encoding: .utf8) {
      var trailingStart = text.startIndex
      if let lastNewline = text.lastIndex(of: "\n") {
        let completeText = String(text[..<text.index(after: lastNewline)])
        for rawLine in completeText.split(separator: "\n", omittingEmptySubsequences: true) {
          if let line = rolloutLineParser(String(rawLine)) {
            events.append(.line(path: path, line: line))
          }
        }
        nextOffset = offset + UInt64(completeText.utf8.count)
        trailingStart = text.index(after: lastNewline)
      }
      let trailing = String(text[trailingStart...])
      if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         let line = rolloutLineParser(trailing) {
        events.append(.line(path: path, line: line))
        nextOffset = UInt64(data.count)
      }
    }
    updateOffset(path: path, offset: nextOffset)
    return events
  }

  private func updateOffset(path: String, offset: UInt64) {
    lock.lock()
    fileOffsets[path] = offset
    lock.unlock()
  }
}
