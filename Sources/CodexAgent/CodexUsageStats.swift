import AgentRuntimeKit
import Foundation

public typealias CodexModelUsageStats = AgentModelUsageStats
public typealias CodexDailyActivity = AgentDailyActivity
public typealias CodexUsageStats = AgentUsageStats

public struct CodexUsageStatsOptions: Equatable, Sendable {
  public var codexSessionsDir: String?
  public var recentDays: Int?
  public var now: Date?

  public init(codexSessionsDir: String? = nil, recentDays: Int? = nil, now: Date? = nil) {
    self.codexSessionsDir = codexSessionsDir
    self.recentDays = recentDays
    self.now = now
  }
}

public enum CodexUsageStatsCollector {
  public static let defaultRecentDays = AgentUsageStatsCollector.defaultRecentDays
  private static let cacheStore = AgentUsageStatsCache()

  public static func getCodexUsageStats(options: CodexUsageStatsOptions = CodexUsageStatsOptions()) -> CodexUsageStats? {
    let sessionsDir = options.codexSessionsDir ?? URL(fileURLWithPath: resolveCodexHome()).appendingPathComponent("sessions").path
    return AgentUsageStatsCollector.collect(
      sessionsDir: sessionsDir,
      recentDays: options.recentDays,
      now: options.now,
      cache: cacheStore,
      readRollout: CodexRolloutReader.readRollout(path:)
    )
  }
}

public func getCodexUsageStats(options: CodexUsageStatsOptions = CodexUsageStatsOptions()) -> CodexUsageStats? {
  CodexUsageStatsCollector.getCodexUsageStats(options: options)
}

extension CodexRolloutLine: AgentUsageStatsRolloutLine {}
