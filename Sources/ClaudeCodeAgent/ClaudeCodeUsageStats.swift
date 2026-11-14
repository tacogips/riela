import AgentRuntimeKit
import Foundation

public typealias ClaudeCodeModelUsageStats = AgentModelUsageStats
public typealias ClaudeCodeDailyActivity = AgentDailyActivity
public typealias ClaudeCodeUsageStats = AgentUsageStats

public struct ClaudeCodeUsageStatsOptions: Equatable, Sendable {
  public var claudeCodeSessionsDir: String?
  public var recentDays: Int?
  public var now: Date?

  public init(claudeCodeSessionsDir: String? = nil, recentDays: Int? = nil, now: Date? = nil) {
    self.claudeCodeSessionsDir = claudeCodeSessionsDir
    self.recentDays = recentDays
    self.now = now
  }
}

public enum ClaudeCodeUsageStatsCollector {
  public static let defaultRecentDays = AgentUsageStatsCollector.defaultRecentDays
  private static let cacheStore = AgentUsageStatsCache()

  public static func getClaudeCodeUsageStats(options: ClaudeCodeUsageStatsOptions = ClaudeCodeUsageStatsOptions()) -> ClaudeCodeUsageStats? {
    let sessionsDir = options.claudeCodeSessionsDir ?? URL(fileURLWithPath: resolveClaudeCodeHome()).appendingPathComponent("sessions").path
    return AgentUsageStatsCollector.collect(
      sessionsDir: sessionsDir,
      recentDays: options.recentDays,
      now: options.now,
      cache: cacheStore,
      readRollout: ClaudeCodeRolloutReader.readRollout(path:)
    )
  }
}

public func getClaudeCodeUsageStats(options: ClaudeCodeUsageStatsOptions = ClaudeCodeUsageStatsOptions()) -> ClaudeCodeUsageStats? {
  ClaudeCodeUsageStatsCollector.getClaudeCodeUsageStats(options: options)
}

extension ClaudeCodeRolloutLine: AgentUsageStatsRolloutLine {}
