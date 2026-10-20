#if os(macOS)
import ServiceManagement
import XCTest
@testable import RielaApp

@MainActor
final class RielaLaunchAtLoginControllerTests: XCTestCase {
  func testCachedPropertiesNeverInvokeReader() async {
    let probe = StatusProbe(value: .enabled)
    let controller = RielaLaunchAtLoginController(readStatus: { probe.read() })

    for _ in 0..<50 {
      _ = controller.isEnabled
      _ = controller.statusDescription
      _ = controller.menuSupplementaryStatusDescription
    }
    XCTAssertEqual(probe.readCount, 0)

    let didRefresh = await controller.refreshStatus()
    XCTAssertTrue(didRefresh)
    for _ in 0..<50 {
      _ = controller.isEnabled
      _ = controller.statusDescription
      _ = controller.menuSupplementaryStatusDescription
    }
    XCTAssertEqual(probe.readCount, 1)
  }

  func testNilStatusShowsOffWithoutSupplementaryLine() {
    let controller = RielaLaunchAtLoginController(readStatus: { .notRegistered })

    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(controller.statusDescription, "Checking")
    XCTAssertNil(controller.menuSupplementaryStatusDescription)
  }

  func testRefreshReportsOnlyRealChanges() async {
    let probe = StatusProbe(value: .notRegistered)
    let controller = RielaLaunchAtLoginController(readStatus: { probe.read() })

    let firstRefreshChanged = await controller.refreshStatus()
    XCTAssertTrue(firstRefreshChanged)
    let unchangedRefreshChanged = await controller.refreshStatus()
    XCTAssertFalse(unchangedRefreshChanged)
    probe.set(.enabled)
    let changedRefreshChanged = await controller.refreshStatus()
    XCTAssertTrue(changedRefreshChanged)
    XCTAssertTrue(controller.isEnabled)
    XCTAssertEqual(controller.statusDescription, "On")
    XCTAssertEqual(probe.readCount, 3)
  }

  func testRequiresApprovalAndNotFoundSurfaceSupplementaryLine() async {
    let probe = StatusProbe(value: .requiresApproval)
    let controller = RielaLaunchAtLoginController(readStatus: { probe.read() })

    let approvalRefreshChanged = await controller.refreshStatus()
    XCTAssertTrue(approvalRefreshChanged)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(controller.menuSupplementaryStatusDescription, "Requires approval in System Settings")

    probe.set(.notFound)
    let notFoundRefreshChanged = await controller.refreshStatus()
    XCTAssertTrue(notFoundRefreshChanged)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(controller.menuSupplementaryStatusDescription, "Unavailable")
  }

  func testLatestRefreshWins() async {
    let started = expectation(description: "first status read started")
    let release = DispatchSemaphore(value: 0)
    let probe = StatusProbe(value: .notRegistered, firstReadStarted: started, firstReadRelease: release)
    let controller = RielaLaunchAtLoginController(readStatus: { probe.read() })
    let firstRefresh = Task { await controller.refreshStatus() }

    await fulfillment(of: [started], timeout: 5)
    let latestRefreshChanged = await controller.refreshStatus()
    XCTAssertTrue(latestRefreshChanged)
    XCTAssertEqual(controller.status, .notRegistered)
    release.signal()
    let supersededRefreshChanged = await firstRefresh.value
    XCTAssertFalse(supersededRefreshChanged)
    XCTAssertEqual(controller.status, .notRegistered)
  }
}

private final class StatusProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value: SMAppService.Status
  private var reads = 0
  private let firstReadStarted: XCTestExpectation?
  private let firstReadRelease: DispatchSemaphore?

  init(
    value: SMAppService.Status,
    firstReadStarted: XCTestExpectation? = nil,
    firstReadRelease: DispatchSemaphore? = nil
  ) {
    self.value = value
    self.firstReadStarted = firstReadStarted
    self.firstReadRelease = firstReadRelease
  }

  var readCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }

  func set(_ value: SMAppService.Status) {
    lock.lock()
    defer { lock.unlock() }
    self.value = value
  }

  func read() -> SMAppService.Status {
    lock.lock()
    reads += 1
    let isFirstRead = reads == 1
    let currentValue = value
    lock.unlock()

    if isFirstRead, let firstReadStarted, let firstReadRelease {
      firstReadStarted.fulfill()
      _ = firstReadRelease.wait(timeout: .now() + 5)
      return .enabled
    }
    return currentValue
  }
}
#endif
