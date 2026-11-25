import Foundation
import RielaCore
import RielaObservability

enum BotRunLinkError: Error {
  case notFound(String)
  case paused(String)

  var code: String {
    switch self {
    case .notFound: "bot_not_found"
    case .paused: "bot_paused"
    }
  }

  static func isBotRejectionMessage(_ message: String) -> Bool {
    [Self.notFound("").code, Self.paused("").code].contains { message.hasPrefix($0 + ":") }
  }

  var message: String {
    switch self {
    case .notFound(let id), .paused(let id): "\(code): \(id)"
    }
  }
}

public struct BotRunLinker: Sendable {
  var sessionStoreRoot: String

  static func resolveSessionStoreRoot(options: WorkflowRunOptions, scope: WorkflowScope) -> String {
    CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: options.sessionStore, scope: scope, workingDirectory: options.workingDirectory
    )
  }

  private var store: BotStore {
    BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
  }

  @discardableResult
  func requireRunnableBot(botId: String) throws -> BotRecord {
    guard let bot = try store.load(botId: botId) else { throw BotRunLinkError.notFound(botId) }
    guard !bot.paused else { throw BotRunLinkError.paused(botId) }
    return bot
  }

  func prepare(botId: String, workingDirectory: String, environment: [String: String]) throws -> BotRunContext {
    let bot = try requireRunnableBot(botId: botId)
    return BotRunContext(
      botId: bot.botId, permissionWaitMs: bot.permissionWaitMs,
      memoryBlock: BotMemoryRuntime.promptBlock(
        botId: bot.botId, sessionStoreRoot: sessionStoreRoot, workingDirectory: workingDirectory, environment: environment
      )
    )
  }

  func link(sessionId: String, botId: String, source: String, sourceRef: String?, at: Date) {
    do {
      try store.linkSession(sessionId: sessionId, botId: botId, source: source, sourceRef: sourceRef, at: at)
    } catch {
      RielaStandardStreams.writeError("riela bot link: \(error)\n")
    }
  }

  static func isPaused(botId: String, sessionStoreRoot: String) -> Bool? {
    (try? Self(sessionStoreRoot: sessionStoreRoot).store.load(botId: botId))?.paused
  }

  public static func botExists(sessionStoreRoot: String) -> @Sendable (String) -> Bool {
    let store = Self(sessionStoreRoot: sessionStoreRoot).store
    return { (try? store.load(botId: $0)) != nil }
  }
}
