import AgentRuntimeKit
import Foundation

public typealias CursorCLIModelUsageStats = AgentModelUsageStats
public typealias CursorCLIDailyActivity = AgentDailyActivity
public typealias CursorCLIUsageStats = AgentUsageStats

public struct CursorCLIUsageStatsOptions: Equatable, Sendable {
  public var cursorCLISessionsDir: String?
  public var recentDays: Int?
  public var now: Date?

  public init(cursorCLISessionsDir: String? = nil, recentDays: Int? = nil, now: Date? = nil) {
    self.cursorCLISessionsDir = cursorCLISessionsDir
    self.recentDays = recentDays
    self.now = now
  }
}

public enum CursorCLIUsageStatsCollector {
  public static let defaultRecentDays = AgentUsageStatsCollector.defaultRecentDays
  private static let cacheStore = AgentUsageStatsCache()

  public static func getCursorCLIUsageStats(options: CursorCLIUsageStatsOptions = CursorCLIUsageStatsOptions()) -> CursorCLIUsageStats? {
    let sessionsDir = options.cursorCLISessionsDir ?? URL(fileURLWithPath: resolveCursorCLIHome()).appendingPathComponent("sessions").path
    return AgentUsageStatsCollector.collect(
      sessionsDir: sessionsDir,
      recentDays: options.recentDays,
      now: options.now,
      cache: cacheStore,
      readRollout: CursorCLIRolloutReader.readRollout(path:)
    )
  }
}

public func getCursorCLIUsageStats(options: CursorCLIUsageStatsOptions = CursorCLIUsageStatsOptions()) -> CursorCLIUsageStats? {
  CursorCLIUsageStatsCollector.getCursorCLIUsageStats(options: options)
}

extension CursorCLIRolloutLine: AgentUsageStatsRolloutLine {}
