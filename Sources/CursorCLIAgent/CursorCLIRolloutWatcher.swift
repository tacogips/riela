import AgentRuntimeKit
import Foundation

public enum CursorCLIRolloutWatcherEvent: Equatable, Sendable {
  case line(path: String, line: CursorCLIRolloutLine)
  case newSession(path: String)
  case error(path: String?, message: String)
}

public final class CursorCLIRolloutWatcher: @unchecked Sendable {
  private let watcher = AgentRolloutWatcher<CursorCLIRolloutLine>(
    rolloutLineParser: CursorCLIRolloutReader.parseRolloutLine
  )

  public init() {}

  public var isClosed: Bool {
    watcher.isClosed
  }

  public static func sessionsWatchDir(cursorCLIHome: String? = nil) -> String {
    URL(fileURLWithPath: cursorCLIHome ?? resolveCursorCLIHome(), isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
      .path
  }

  public func watchFile(path: String, startOffset: UInt64? = nil) {
    watcher.watchFile(path: path, startOffset: startOffset)
  }

  public func watchSessionsDirectory(path: String) {
    watcher.watchSessionsDirectory(path: path)
  }

  public func flush() -> [CursorCLIRolloutWatcherEvent] {
    watcher.flush().map(Self.event(from:))
  }

  public func stop() {
    watcher.stop()
  }

  private static func event(from event: AgentRolloutWatcherEvent<CursorCLIRolloutLine>) -> CursorCLIRolloutWatcherEvent {
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
