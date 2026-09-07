import Foundation
import XCTest
@testable import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class POSIXDirectoryEntryNameTests: XCTestCase {
  func testShortDirectoryRecordImmediatelyBeforeGuardPageDoesNotOverread() throws {
    let pageSize = Int(getpagesize())
    let allocation = try XCTUnwrap(mmap(nil, pageSize * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
    guard allocation != MAP_FAILED else { throw POSIXError(.ENOMEM) }
    defer { munmap(allocation, pageSize * 2) }
    XCTAssertEqual(mprotect(allocation.advanced(by: pageSize), pageSize, PROT_NONE), 0)
    let offset = try XCTUnwrap(MemoryLayout<dirent>.offset(of: \.d_name))
    let recordSize = 64
    XCTAssertLessThan(offset + 8, recordSize)
    let record = allocation.advanced(by: pageSize - recordSize).assumingMemoryBound(to: dirent.self)
    record.pointee.d_reclen = UInt16(recordSize)
    let bytes = UnsafeMutableRawPointer(record).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
    for (index, byte) in Array("entry\0".utf8).enumerated() { bytes[index] = byte }
    XCTAssertEqual(try posixDirectoryEntryName(record), "entry")
  }

  func testUnterminatedDirectoryRecordFailsWithinItsDeclaredBounds() throws {
    let offset = try XCTUnwrap(MemoryLayout<dirent>.offset(of: \.d_name))
    var record = dirent()
    record.d_reclen = UInt16(offset + 1)
    try withUnsafeMutablePointer(to: &record) { pointer in
      UnsafeMutableRawPointer(pointer).advanced(by: offset).storeBytes(of: UInt8(65), as: UInt8.self)
      XCTAssertThrowsError(try posixDirectoryEntryName(pointer))
    }
  }
}
