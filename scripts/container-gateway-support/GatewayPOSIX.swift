// Linux adapters for the pinned gateway's descriptor-relative file operations.
// Keep exclusive publication and exchange semantics identical on both platforms.
#if os(Linux)
import Glibc

@_silgen_name("renameat2")
private func linuxRenameAt2(_ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>, _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>, _ flags: UInt32) -> Int32

@_silgen_name("flock")
func gatewayFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

let gatewayRenameExclusive: UInt32 = 4
let gatewayRenameExchange: UInt32 = 2

func renameatx_np(_ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>, _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
  let linuxFlags: UInt32
  switch flags {
  case gatewayRenameExclusive: linuxFlags = 1 // RENAME_NOREPLACE
  case gatewayRenameExchange: linuxFlags = 2 // RENAME_EXCHANGE
  default:
    errno = EINVAL
    return -1
  }
  return linuxRenameAt2(oldDirectory, oldPath, newDirectory, newPath, linuxFlags)
}

// The upstream SDK qualifies POSIX calls with Darwin to avoid member-name
// collisions. Supply the same namespace on Linux without changing its checks.
enum Darwin {
  static func open(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    Glibc.open(path, flags)
  }
  static func open(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    Glibc.open(path, flags, mode)
  }
  static func openat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    Glibc.openat(directory, path, flags)
  }
  static func openat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    Glibc.openat(directory, path, flags, mode)
  }
  @discardableResult static func close(_ descriptor: Int32) -> Int32 { Glibc.close(descriptor) }
  static func fchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 { Glibc.fchmod(descriptor, mode) }
  static func fstat(_ descriptor: Int32, _ status: UnsafeMutablePointer<stat>) -> Int32 {
    Glibc.fstat(descriptor, status)
  }
  static func fstatat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ status: UnsafeMutablePointer<stat>, _ flags: Int32) -> Int32 {
    Glibc.fstatat(directory, path, status, flags)
  }
  static func fsync(_ descriptor: Int32) -> Int32 { Glibc.fsync(descriptor) }
  static func geteuid() -> uid_t { Glibc.geteuid() }
  @discardableResult static func lockf(_ descriptor: Int32, _ operation: Int32, _ length: off_t) -> Int32 {
    Glibc.lockf(descriptor, operation, length)
  }
  static func mkdirat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 {
    Glibc.mkdirat(directory, path, mode)
  }
  static func renameat(_ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>, _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>) -> Int32 {
    Glibc.renameat(oldDirectory, oldPath, newDirectory, newPath)
  }
  static func renameatx_np(_ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>, _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
    // Call the file-level adapter explicitly through a uniquely named helper.
    gatewayRename(oldDirectory, oldPath, newDirectory, newPath, flags)
  }
  static func unlinkat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    Glibc.unlinkat(directory, path, flags)
  }
  static func write(_ descriptor: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
    Glibc.write(descriptor, bytes, count)
  }
}

private func gatewayRename(_ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>, _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
  renameatx_np(oldDirectory, oldPath, newDirectory, newPath, flags)
}
#else
import Darwin

let gatewayRenameExclusive = UInt32(RENAME_EXCL)
let gatewayRenameExchange = UInt32(RENAME_SWAP)

func gatewayFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
  flock(descriptor, operation)
}
#endif
