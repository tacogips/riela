import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func nativeSandboxPhysicalPath(_ url: URL) -> String {
  if let path = realpath(url.path, nil) {
    defer { free(path) }
    return String(cString: path)
  }
  let parent = url.deletingLastPathComponent()
  guard parent.path != url.path else { return url.path }
  return nativeSandboxPhysicalPath(parent) + "/" + url.lastPathComponent
}

enum NativeSandboxSeccomp {
  private struct Instruction {
    var code: UInt16
    var yes: UInt8
    var no: UInt8
    var value: UInt32

    init(_ code: UInt16, _ yes: UInt8, _ no: UInt8, _ value: UInt32) {
      self.code = code
      self.yes = yes
      self.no = no
      self.value = value
    }
  }
  /// Deny named Unix sockets even when internet egress shares the host's
  /// network namespace. Keep socketpair available for private in-process IPC.
  static func socketFilter() throws -> Data {
    #if arch(arm64)
    let architecture: UInt32 = 0xc00000b7
    let socket: UInt32 = 198
    let socketPair: UInt32 = 199
    #elseif arch(x86_64)
    let architecture: UInt32 = 0xc000003e
    let socket: UInt32 = 41
    let socketPair: UInt32 = 53
    #else
    throw AdapterExecutionError(.policyBlocked, "bubblewrap syscall policy requires arm64 or x86_64")
    #endif
    #if arch(arm64) || arch(x86_64)
    // sock_filter: code (u16), jt (u8), jf (u8), k (u32), native endian.
    let instructions: [Instruction] = [
      .init(0x20, 0, 0, 4),                       // load seccomp_data.arch
      .init(0x15, 1, 0, architecture),
      .init(0x06, 0, 0, 0x80000000),              // kill incompatible ABI
      .init(0x20, 0, 0, 0),                       // load syscall number
      .init(0x35, 15, 0, 0x40000000),             // reject x32 ABI
      .init(0x15, 14, 0, 425),                    // io_uring can bypass socket syscall filters
      .init(0x15, 2, 0, socket),
      .init(0x15, 5, 0, socketPair),
      .init(0x06, 0, 0, 0x7fff0000),              // other syscalls
      .init(0x20, 0, 0, 16),                      // socket: domain
      .init(0x15, 8, 0, 2),                       // AF_INET
      .init(0x15, 7, 0, 10),                      // AF_INET6
      .init(0x06, 0, 0, 0x00050001),              // reject other socket domains
      .init(0x20, 0, 0, 16),                      // socketpair: domain
      .init(0x15, 0, 5, 1),                       // AF_UNIX only
      .init(0x20, 0, 0, 24),                      // socketpair: type
      .init(0x54, 0, 0, 0x0f),                    // mask CLOEXEC/NONBLOCK
      .init(0x15, 1, 2, 1),                       // SOCK_STREAM only; datagrams can reconnect
      .init(0x06, 0, 0, 0x00050001),
      .init(0x06, 0, 0, 0x7fff0000),              // allow
      .init(0x06, 0, 0, 0x00050001)               // EPERM
    ]
    var data = Data()
    for instruction in instructions {
      var code = instruction.code
      var value = instruction.value
      withUnsafeBytes(of: &code) { data.append(contentsOf: $0) }
      data.append(contentsOf: [instruction.yes, instruction.no])
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
    #endif
  }
}
