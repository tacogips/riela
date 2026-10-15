import Foundation
import XCTest
@testable import RielaAdapters

final class NativeSandboxSeccompTests: XCTestCase {
  func testCompiledFilterRejectsHostIPCAndAlternateSocketEntryPoints() throws {
    #if arch(arm64)
    let architecture: UInt32 = 0xc00000b7
    let socket: UInt32 = 198
    let pair: UInt32 = 199
    #else
    let architecture: UInt32 = 0xc000003e
    let socket: UInt32 = 41
    let pair: UInt32 = 53
    #endif
    let filter = try NativeSandboxSeccomp.socketFilter()
    for family: UInt32 in [2, 10] {
      XCTAssertEqual(try evaluate(filter, values: [0: socket, 4: architecture, 16: family]), 0x7fff0000)
    }
    for family: UInt32 in [1, 16, 17] {
      XCTAssertEqual(try evaluate(filter, values: [0: socket, 4: architecture, 16: family]), 0x00050001)
    }
    XCTAssertEqual(try evaluate(filter, values: [0: pair, 4: architecture, 16: 1, 24: 1 | 0x80800]), 0x7fff0000)
    for type: UInt32 in [2, 5] {
      XCTAssertEqual(try evaluate(filter, values: [0: pair, 4: architecture, 16: 1, 24: type]), 0x00050001)
    }
    for syscall: UInt32 in [425, 0x40000000 | socket] {
      XCTAssertEqual(try evaluate(filter, values: [0: syscall, 4: architecture]), 0x00050001)
    }
    XCTAssertEqual(try evaluate(filter, values: [0: socket, 4: 0x40000003]), 0x80000000)
    XCTAssertEqual(try evaluate(filter, values: [0: 0, 4: architecture]), 0x7fff0000)
  }

  /// Execute the emitted BPF bytes against syscall data, independently of the
  /// source instruction layout. This checks jump destinations as well as rules.
  private func evaluate(_ program: Data, values: [UInt32: UInt32]) throws -> UInt32 {
    var accumulator: UInt32 = 0
    var offset = 0
    for _ in 0..<50 {
      guard offset >= 0, offset + 8 <= program.count else { throw InvalidProgram() }
      let code = program.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
      let value = program.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
      let yes = Int(program[offset + 2])
      let no = Int(program[offset + 3])
      switch code {
      case 0x20: accumulator = values[value] ?? 0
      case 0x15: offset += 8 * (accumulator == value ? yes : no)
      case 0x35: offset += 8 * (accumulator >= value ? yes : no)
      case 0x54: accumulator &= value
      case 0x06: return value
      default: throw InvalidProgram()
      }
      offset += 8
    }
    throw InvalidProgram()
  }

  private struct InvalidProgram: Error {}
}
