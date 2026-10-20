import Foundation
import RielaCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct RetentionLogPruner {
  var now: () -> Date
  var beforeUnlink: ((String) -> Void)?

  func run(logsRoot: String, state: RielaRetentionCategoryState, policy: RetentionPolicySnapshot?,
           dryRun: Bool, removalLimit: Int = 1000) -> (report: RetentionCategoryReport, warnings: [String]) {
    guard state == .active else { return (.inactive(state), []) }
    guard let policy else { return (.inactive(.notConfigured), []) }
    var rootInfo = stat()
    guard lstat(logsRoot, &rootInfo) == 0, (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
      return (.inactive(state), [])
    }
    let names: [String]
    do { names = try FileManager.default.contentsOfDirectory(atPath: logsRoot).sorted() } catch {
      return (report(state: state, policy: policy, selected: 0, removed: 0, selectedBytes: 0,
        removedBytes: 0, before: 0, protected: ["readError": 1], workLimit: false), [error.localizedDescription])
    }

    let entries = names.compactMap { entry(path: URL(fileURLWithPath: logsRoot).appendingPathComponent($0).path, name: $0) }
    let plan: RielaLogRetentionPlan
    do {
      plan = try RielaLogRetentionPlan.make(entries: entries, now: now(),
        maxAge: policy.maxAgeDays.map { TimeInterval($0) * 86_400 }, maxBytes: policy.maxTotalBytes,
        removalLimit: removalLimit)
    } catch {
      return (report(state: state, policy: policy, selected: 0, removed: 0, selectedBytes: 0,
        removedBytes: 0, before: 0, protected: ["invalidPlan": 1], workLimit: false), [error.localizedDescription])
    }

    var warnings: [String] = []
    var protected = plan.protected
    var removedCount = 0
    var removedBytes: Int64 = 0
    if !dryRun {
      for selected in plan.selected {
        let path = URL(fileURLWithPath: logsRoot).appendingPathComponent(selected.name).path
        beforeUnlink?(path)
        guard let current = entry(path: path, name: selected.name), current.kind == .regular,
              current.device == selected.device, current.inode == selected.inode,
              current.size == selected.size, current.modifiedAt == selected.modifiedAt else {
          protected["changedDuringAdmission", default: 0] += 1
          continue
        }
        guard unlink(path) == 0 else {
          warnings.append("Could not remove retention log '\(selected.name)': \(String(cString: strerror(errno)))")
          continue
        }
        removedCount += 1
        removedBytes += selected.size
      }
    }
    return (report(state: state, policy: policy, selected: plan.selected.count, removed: removedCount,
      selectedBytes: plan.selected.reduce(Int64(0)) { $0 + $1.size }, removedBytes: removedBytes,
      before: plan.beforeBytes, protected: protected, workLimit: plan.workLimitReached), warnings)
  }

  private func entry(path: String, name: String) -> RielaLogFileEntry? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    let type = info.st_mode & mode_t(S_IFMT)
    let kind: RielaLogFileEntry.Kind
    switch type {
    case mode_t(S_IFREG): kind = .regular
    case mode_t(S_IFLNK): kind = .symlink
    case mode_t(S_IFDIR): kind = .directory
    default: kind = .other
    }
    #if os(Linux)
    let modifiedAt = Date(timeIntervalSince1970: TimeInterval(info.st_mtim.tv_sec) + TimeInterval(info.st_mtim.tv_nsec) / 1_000_000_000)
    #else
    let modifiedAt = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    #endif
    return RielaLogFileEntry(name: name, kind: kind, size: max(0, Int64(info.st_size)), modifiedAt: modifiedAt,
      device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
  }

  private func report(state: RielaRetentionCategoryState, policy: RetentionPolicySnapshot,
                      selected: Int, removed: Int, selectedBytes: Int64, removedBytes: Int64,
                      before: Int64, protected: [String: Int], workLimit: Bool) -> RetentionCategoryReport {
    let remaining = max(0, before - removedBytes)
    return RetentionCategoryReport(state: state, policy: policy, selectedCount: selected, removedCount: removed,
      selectedBytes: selectedBytes, removedBytes: removedBytes, beforeBytes: before, remainingBytes: remaining,
      capAchieved: policy.maxTotalBytes.map { remaining <= $0 }, protected: protected, protectedFamilies: [],
      pendingCleanupCount: 0, workLimitReached: workLimit, orphanSessionCount: 0)
  }
}
