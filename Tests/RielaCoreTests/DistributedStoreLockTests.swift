import Foundation
import XCTest
@testable import RielaCore

final class DistributedStoreLockTests: XCTestCase {
  func testNestedAcquisitionOnSamePathIsReentrant() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lockURL = root.appendingPathComponent("store.lock")
    let completed = expectation(description: "nested lock acquisition completes")
    DispatchQueue.global().async {
      do {
        let outer = try DistributedStoreLock(url: lockURL)
        let inner = try DistributedStoreLock(url: lockURL)
        try outer.acquire()
        defer { outer.release() }
        try inner.acquire()
        inner.release()
        completed.fulfill()
      } catch { XCTFail("nested lock failed: \(error)") }
    }
    wait(for: [completed], timeout: 2)
  }
}
