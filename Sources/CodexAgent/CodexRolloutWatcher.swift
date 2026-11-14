import AgentRuntimeKit
import Foundation

public enum CodexRolloutWatcherEvent: Equatable, Sendable {
  case line(path: String, line: CodexRolloutLine)
  case newSession(path: String)
  case error(path: String?, message: String)
}

public final class CodexRolloutWatcher: @unchecked Sendable {
  private let watcher = AgentRolloutWatcher<CodexRolloutLine>(
    rolloutLineParser: CodexRolloutReader.parseRolloutLine
  )

  public init() {}

  public var isClosed: Bool {
    watcher.isClosed
  }

  public static func sessionsWatchDir(codexHome: String? = nil) -> String {
    URL(fileURLWithPath: codexHome ?? resolveCodexHome(), isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true)
      .path
  }

  public func watchFile(path: String, startOffset: UInt64? = nil) {
    watcher.watchFile(path: path, startOffset: startOffset)
  }

  public func watchSessionsDirectory(path: String) {
    watcher.watchSessionsDirectory(path: path)
  }

  public func flush() -> [CodexRolloutWatcherEvent] {
    watcher.flush().map(Self.event(from:))
  }

  public func stop() {
    watcher.stop()
  }

  private static func event(from event: AgentRolloutWatcherEvent<CodexRolloutLine>) -> CodexRolloutWatcherEvent {
    switch event {
    case let .line(path, line):
      return .line(path: path, line: line)
    case let .newSession(path):
      return .newSession(path: path)
    case let .error(path, message):
      return .error(path: path, message: message)
    }
  }
}
