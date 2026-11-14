import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RetentionTargetStateTests: XCTestCase {
  func testResolvesUserAndProjectTargetsInOrder() throws {
    let root = try fixture()
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try makeRielaRoot(home)
    try makeRielaRoot(project)

    let targets = RetentionTargetResolver.resolve(scope: .all, homeDirectory: home,
      projectDirectory: project, explicitSessionStore: nil, environment: [:])

    XCTAssertEqual(targets.map(\.kind), [.user, .project])
    XCTAssertEqual(targets[0].sessionStoreRoot, home.appendingPathComponent(".riela/sessions").path)
    XCTAssertEqual(targets[0].logsRoot, home.appendingPathComponent(".riela/logs").path)
    XCTAssertEqual(targets[1].stateDirectory, project.appendingPathComponent(".riela/retention").path)
  }

  func testProjectEqualToHomeIsDeduplicated() throws {
    let root = try fixture()
    let home = root.appendingPathComponent("home", isDirectory: true)
    try makeRielaRoot(home)
    let targets = RetentionTargetResolver.resolve(scope: .all, homeDirectory: home,
      projectDirectory: home, explicitSessionStore: nil, environment: [:])
    XCTAssertEqual(targets.map(\.kind), [.user])
  }

  func testExplicitStoreMatchingUserStoreIsDeduplicated() throws {
    let root = try fixture()
    let home = root.appendingPathComponent("home", isDirectory: true)
    try makeRielaRoot(home)
    let store = home.appendingPathComponent(".riela/sessions")
    let targets = RetentionTargetResolver.resolve(scope: .all, homeDirectory: home,
      projectDirectory: nil, explicitSessionStore: nil, environment: ["RIELA_SESSION_STORE": store.path])
    XCTAssertEqual(targets.count, 1)
  }

  func testSeparateExplicitTargetUsesMemoryOverrideAndNoLogsRoot() throws {
    let root = try fixture()
    let explicit = root.appendingPathComponent("custom-store", isDirectory: true)
    let memory = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: explicit, withIntermediateDirectories: true)
    let targets = RetentionTargetResolver.resolve(scope: .all,
      homeDirectory: root.appendingPathComponent("missing-home"), projectDirectory: nil,
      explicitSessionStore: explicit.path, environment: ["RIELA_MEMORY_ROOT": memory.path])
    XCTAssertEqual(targets.count, 1)
    XCTAssertEqual(targets[0].kind, .explicit)
    XCTAssertEqual(targets[0].memoryRoot, memory.path)
    XCTAssertNil(targets[0].logsRoot)
  }

  func testRelativeExplicitStoreResolvesAgainstProjectDirectory() throws {
    let root = try fixture()
    let project = root.appendingPathComponent("project", isDirectory: true)
    try makeRielaRoot(project)
    let explicit = project.appendingPathComponent("custom-store", isDirectory: true)
    try FileManager.default.createDirectory(at: explicit, withIntermediateDirectories: true)
    let targets = RetentionTargetResolver.resolve(scope: .all,
      homeDirectory: root.appendingPathComponent("missing-home"), projectDirectory: project,
      explicitSessionStore: "custom-store", environment: [:])
    XCTAssertEqual(targets.last?.root, explicit.path)
  }

  func testMissingProjectIsSkippedWithoutCreatingIt() throws {
    let root = try fixture()
    let missing = root.appendingPathComponent("missing-project", isDirectory: true)
    let targets = RetentionTargetResolver.resolve(scope: .project, homeDirectory: root,
      projectDirectory: missing, explicitSessionStore: nil, environment: [:])
    XCTAssertTrue(targets.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.appendingPathComponent(".riela").path))
  }

  func testSymlinkRootIsMarkedUnsafe() throws {
    let root = try fixture()
    let home = root.appendingPathComponent("home", isDirectory: true)
    let real = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try makeRielaRoot(real)
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".riela"), withDestinationURL: real.appendingPathComponent(".riela"))
    let targets = RetentionTargetResolver.resolve(scope: .user, homeDirectory: home,
      projectDirectory: nil, explicitSessionStore: nil, environment: [:])
    XCTAssertEqual(targets.first?.unsafeReason, "unsafePath")
  }

  func testTargetLockIsNonblockingAndReacquirable() throws {
    let directory = try fixture().appendingPathComponent("retention", isDirectory: true)
    do {
      let first = try XCTUnwrap(RetentionTargetLock.tryAcquire(stateDirectory: directory.path))
      XCTAssertNil(try RetentionTargetLock.tryAcquire(stateDirectory: directory.path))
      withExtendedLifetime(first) {}
    }
    XCTAssertNotNil(try RetentionTargetLock.tryAcquire(stateDirectory: directory.path))
  }

  func testStampRoundTripAndFreshnessIncludingFutureTimestamp() throws {
    let directory = try fixture().appendingPathComponent("retention", isDirectory: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stamp = RetentionRunStamp(lastAttemptAt: now.addingTimeInterval(-600),
      lastCompletedAt: now.addingTimeInterval(-590), lastStatus: "completed")
    try stamp.write(stateDirectory: directory.path)
    XCTAssertEqual(RetentionRunStamp.read(stateDirectory: directory.path), stamp)
    XCTAssertTrue(RetentionRunStamp.isFresh(stamp, now: now, minInterval: 3_600))
    XCTAssertFalse(RetentionRunStamp.isFresh(stamp, now: now, minInterval: 599))
    let future = RetentionRunStamp(lastAttemptAt: now.addingTimeInterval(1))
    XCTAssertFalse(RetentionRunStamp.isFresh(future, now: now, minInterval: 3_600))
  }

  private func fixture() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/automatic-retention-target-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeRielaRoot(_ home: URL) throws {
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".riela"), withIntermediateDirectories: true)
  }
}
