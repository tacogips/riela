#if os(macOS)
import Foundation
import XCTest
import RielaCLI
@testable import RielaApp

final class RielaAppRetentionStartTests: XCTestCase {
  func testRequestUsesInjectedHomeAndSkipsMissingProjectRoot() throws {
    let home = try makeRoot()
    let request = rielaAppRetentionRequest(
      homeDirectory: home,
      projectRoot: nil,
      environment: ["HOME": home.path]
    )

    XCTAssertEqual(request.trigger, .automatic)
    XCTAssertEqual(request.scope, .all)
    XCTAssertNil(request.projectDirectory)
    XCTAssertEqual(request.homeDirectory, home)
  }

  func testConfiguredLogsPolicyPrunesOnlyInjectedHome() throws {
    let home = try makeRoot()
    let rielaRoot = home.appendingPathComponent(".riela", isDirectory: true)
    let logs = rielaRoot.appendingPathComponent("logs", isDirectory: true)
    let oldLog = logs.appendingPathComponent("a.jsonl")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try Data("old log".utf8).write(to: oldLog)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)],
      ofItemAtPath: oldLog.path
    )
    try Data(#"{"retention":{"logs":{"maxAgeDays":14}}}"#.utf8).write(
      to: rielaRoot.appendingPathComponent("config.json")
    )
    let request = rielaAppRetentionRequest(
      homeDirectory: home,
      projectRoot: nil,
      environment: ["HOME": home.path]
    )

    let report = try RielaRetentionService(clock: { Date(timeIntervalSince1970: 2_000_000) }).run(request)

    XCTAssertFalse(FileManager.default.fileExists(atPath: oldLog.path))
    XCTAssertEqual(report.targets.count, 1)
    XCTAssertEqual(report.targets.first?.kind, .user)
    XCTAssertEqual(report.targets.first?.root, rielaRoot.path)
    XCTAssertTrue(report.targets.allSatisfy { $0.root.hasPrefix(home.path) })
  }

  func testMissingConfigurationAppliesBuiltInDefaults() throws {
    let home = try makeRoot()
    let rielaRoot = home.appendingPathComponent(".riela", isDirectory: true)
    let logs = rielaRoot.appendingPathComponent("logs", isDirectory: true)
    let recentLog = logs.appendingPathComponent("recent.jsonl")
    let now = Date(timeIntervalSince1970: 2_000_000)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try Data("recent log".utf8).write(to: recentLog)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: recentLog.path
    )
    let request = rielaAppRetentionRequest(
      homeDirectory: home,
      projectRoot: nil,
      environment: ["HOME": home.path]
    )

    let report = try RielaRetentionService(clock: { now }).run(request)

    XCTAssertEqual(report.targets.count, 1)
    XCTAssertEqual(report.targets.first?.kind, .user)
    XCTAssertEqual(report.targets.first?.root, rielaRoot.path)
    XCTAssertEqual(report.targets.first?.results.policySource, .builtInDefault)
    XCTAssertEqual(report.targets.first?.logs.policySource, .builtInDefault)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recentLog.path))
    XCTAssertTrue(report.targets.allSatisfy { $0.root.hasPrefix(home.path) })
  }

  private func makeRoot() throws -> URL {
    let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let base = repositoryRoot.appendingPathComponent("tmp/automatic-retention/app-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath().standardizedFileURL
  }

  override func tearDown() {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/automatic-retention/app-tests", isDirectory: true)
    if let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
      for entry in entries { try? FileManager.default.removeItem(at: entry) }
    }
    super.tearDown()
  }
}
#endif
