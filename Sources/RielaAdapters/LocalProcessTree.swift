import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct LocalProcessTreeEntry: Equatable, Sendable {
  let pid: pid_t
  let ppid: pid_t
  let pgid: pid_t
  let startTime: UInt64
}

protocol LocalProcessTreeSnapshotting: Sendable {
  func snapshot() -> [LocalProcessTreeEntry]
}

struct SystemLocalProcessTreeSnapshotter: LocalProcessTreeSnapshotting {
  func snapshot() -> [LocalProcessTreeEntry] {
    #if canImport(Darwin)
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    let mibCount = u_int(mib.count)
    while true {
      var size = 0
      guard sysctl(&mib, mibCount, nil, &size, nil, 0) == 0 else { return [] }
      var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
      size = processes.count * MemoryLayout<kinfo_proc>.stride
      let result = processes.withUnsafeMutableBytes { buffer in
        sysctl(&mib, mibCount, buffer.baseAddress, &size, nil, 0)
      }
      if result != 0 {
        if errno == ENOMEM { continue }
        return []
      }
      return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map { process in
        let start = process.kp_proc.p_starttime
        return LocalProcessTreeEntry(pid: process.kp_proc.p_pid, ppid: process.kp_eproc.e_ppid,
                                     pgid: process.kp_eproc.e_pgid,
                                     startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
      }
    }
    #else
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
    return names.compactMap { name in
      guard let pid = pid_t(name),
            let stat = try? String(contentsOfFile: "/proc/\(name)/stat", encoding: .utf8),
            let end = stat.lastIndex(of: ")") else { return nil }
      let fields = stat[stat.index(after: end)...].split(separator: " ")
      guard fields.count > 19, let ppid = pid_t(fields[1]), let pgid = pid_t(fields[2]),
            let start = UInt64(fields[19]) else { return nil }
      return LocalProcessTreeEntry(pid: pid, ppid: ppid, pgid: pgid, startTime: start)
    }
    #endif
  }
}

func localProcessDescendants(of roots: Set<pid_t>, in entries: [LocalProcessTreeEntry]) -> [LocalProcessTreeEntry] {
  var parents = roots
  var result: [LocalProcessTreeEntry] = []
  var seen = roots
  while !parents.isEmpty {
    let children = entries.filter { parents.contains($0.ppid) && !seen.contains($0.pid) }
    guard !children.isEmpty else { break }
    result.append(contentsOf: children)
    parents = Set(children.map(\.pid))
    seen.formUnion(parents)
  }
  return result
}
