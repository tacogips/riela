import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Real process observation for terminal tool-child classification.
/// Darwin reads `sysctl KERN_PROC_PID` (zombie = `SZOMB`); Linux reads
/// `/proc/<pid>/stat` (state `Z`). The start identity is the kernel's
/// process start time, which distinguishes a reused PID from the recorded
/// child.
public struct SystemAgentProcessStateProber: AgentProcessStateProbing {
  public init() {}

  public func probe(processId: Int32) -> AgentProbedProcess {
    #if os(Linux)
    return Self.probeLinux(processId: processId)
    #else
    return Self.probeDarwin(processId: processId)
    #endif
  }

  #if os(Linux)
  static func probeLinux(processId: Int32) -> AgentProbedProcess {
    guard let stat = try? String(contentsOfFile: "/proc/\(processId)/stat", encoding: .utf8) else {
      return AgentProbedProcess(state: .missing)
    }
    // Fields after the parenthesized comm: state ppid pgrp ... starttime(22).
    guard let commEnd = stat.range(of: ") ", options: .backwards) else {
      return AgentProbedProcess(state: .missing)
    }
    let fields = stat[commEnd.upperBound...].split(separator: " ").map(String.init)
    guard fields.count >= 20 else {
      return AgentProbedProcess(state: .missing)
    }
    let state: AgentProbedProcessState = fields[0] == "Z" ? .zombie : .running
    let parent = Int32(fields[1])
    let startIdentity = fields.count >= 20 ? fields[19] : nil
    return AgentProbedProcess(state: state, parentProcessId: parent, startIdentity: startIdentity)
  }
  #else
  static func probeDarwin(processId: Int32) -> AgentProbedProcess {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processId]
    let result = mib.withUnsafeMutableBufferPointer { pointer in
      sysctl(pointer.baseAddress, UInt32(pointer.count), &info, &size, nil, 0)
    }
    guard result == 0, size > 0, info.kp_proc.p_pid == processId else {
      return AgentProbedProcess(state: .missing)
    }
    // SZOMB == 5 (sys/proc.h); the constant is not imported into Swift.
    let state: AgentProbedProcessState = Int32(info.kp_proc.p_stat) == 5 ? .zombie : .running
    let start = info.kp_proc.p_starttime
    return AgentProbedProcess(
      state: state,
      parentProcessId: Int32(info.kp_eproc.e_ppid),
      startIdentity: "\(start.tv_sec).\(start.tv_usec)"
    )
  }
  #endif
}

/// Discovers live child processes of an owning agent process so a started
/// tool call can be bound to the descendant executing it. Injectable; the
/// system implementation scans the process table.
public protocol AgentChildProcessDiscovering: Sendable {
  func childProcessIds(of parentProcessId: Int32) -> [Int32]
}

public struct SystemAgentChildProcessDiscoverer: AgentChildProcessDiscovering {
  public init() {}

  public func childProcessIds(of parentProcessId: Int32) -> [Int32] {
    #if os(Linux)
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
      return []
    }
    return entries.compactMap { entry -> Int32? in
      guard let pid = Int32(entry) else {
        return nil
      }
      let probed = SystemAgentProcessStateProber.probeLinux(processId: pid)
      return probed.parentProcessId == parentProcessId ? pid : nil
    }.sorted()
    #else
    // KERN_PROC_ALL scan kept simple: `pgrep -P` is present on macOS and
    // avoids a variable-length sysctl buffer dance.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-P", String(parentProcessId)]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else {
      return []
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else {
      return []
    }
    return text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.sorted()
    #endif
  }
}
