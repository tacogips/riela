import Foundation
import XCTest
@testable import RielaCore

final class RielaRetentionConfigurationTests: XCTestCase {
  func testMissingConfigurationHasNoPolicies() throws {
    let home = try makeRoot()
    defer { try? FileManager.default.removeItem(at: home) }

    let config = try load(home: home)

    XCTAssertNil(config.userPolicy)
    XCTAssertNil(config.projectPolicy)
  }

  func testRetentionDefaultsAndCategoryStates() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"maxAgeDays":30}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }

    let policy = try XCTUnwrap(load(home: home).userPolicy)

    XCTAssertTrue(policy.automatic)
    XCTAssertEqual(policy.minIntervalMinutes, 60)
    XCTAssertEqual(policy.results.state, .active)
    XCTAssertEqual(policy.messages.state, .notConfigured)
    XCTAssertEqual(policy.logs.state, .notConfigured)
  }

  func testKeepForeverExampleAndDecimalByteLimit() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"keepForever":true},"messages":{"keepForever":true},"logs":{"maxAgeDays":14,"maxTotalBytes":"1GB"}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }

    let policy = try XCTUnwrap(load(home: home).userPolicy)

    XCTAssertEqual(policy.results.state, .keepForever)
    XCTAssertEqual(policy.messages.state, .keepForever)
    XCTAssertEqual(policy.logs.maxTotalBytes, 1_000_000_000)
  }

  func testByteSizeParsesDecimalAndBinaryUnits() throws {
    XCTAssertEqual(try RielaByteSize.parse("5GB"), 5_000_000_000)
    XCTAssertEqual(try RielaByteSize.parse("1GiB"), 1_073_741_824)
    XCTAssertEqual(try RielaByteSize.parse("12 kb"), 12_000)
  }

  func testByteSizeRejectsInvalidInputs() {
    for value in ["1.5GB", "-1MB", "12", "0B", "", "999999999999999999999TB"] {
      XCTAssertThrowsError(try RielaByteSize.parse(value), "\(value) must fail")
    }
  }

  func testRemovedConfigurationKeyHasExactError() throws {
    let home = try makeRoot(configuration: #"{"gc":{"retentionDays":30}}"#)
    defer { try? FileManager.default.removeItem(at: home) }

    XCTAssertThrowsError(try load(home: home)) { error in
      XCTAssertEqual(error as? RielaRetentionConfigurationError, .removedKey("gc"))
      XCTAssertEqual(error.localizedDescription, "gc.retentionDays was removed; configure \"retention\" (see riela gc --help)")
    }
  }

  func testRemovedEnvironmentKeyFails() throws {
    let home = try makeRoot()
    defer { try? FileManager.default.removeItem(at: home) }

    XCTAssertThrowsError(try load(home: home, environment: ["RIELA_GC_RETENTION_DAYS": "14"])) { error in
      XCTAssertEqual(error as? RielaRetentionConfigurationError, .removedKey("RIELA_GC_RETENTION_DAYS"))
    }
  }

  func testEmptyRemovedEnvironmentKeyIsIgnored() throws {
    let home = try makeRoot()
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertNil(try load(home: home, environment: ["RIELA_GC_RETENTION_DAYS": ""]).userPolicy)
  }

  func testUnknownRetentionKeyReportsItsPath() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"maxAge":3}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }

    XCTAssertThrowsError(try load(home: home)) { error in
      guard case let RielaRetentionConfigurationError.invalid(path, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, "retention.results.maxAge")
    }
  }

  func testKeepWorkflowIdsOnlyAllowedForResults() throws {
    let home = try makeRoot(configuration: #"{"retention":{"logs":{"keepWorkflowIds":["demo"]}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertThrowsError(try load(home: home))
  }

  func testKeepForeverCannotCombineWithLimits() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"keepForever":true,"maxAgeDays":1}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertThrowsError(try load(home: home))
  }

  func testAgeAndIntervalRangesAreValidated() throws {
    for json in [
      #"{"retention":{"results":{"maxAgeDays":0}}}"#,
      #"{"retention":{"results":{"maxAgeDays":36501}}}"#,
      #"{"retention":{"minIntervalMinutes":0}}"#
    ] {
      let home = try makeRoot(configuration: json)
      defer { try? FileManager.default.removeItem(at: home) }
      XCTAssertThrowsError(try load(home: home), json)
    }
  }

  func testProjectPolicyReplacesUserPolicyAndExplicitUsesUser() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"maxAgeDays":30}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent("project", isDirectory: true)
    try writeConfiguration(#"{"retention":{"logs":{"maxAgeDays":14}}}"#, in: project)

    let config = try load(home: home, project: project)

    XCTAssertEqual(config.policy(for: .user)?.results.maxAgeDays, 30)
    XCTAssertEqual(config.policy(for: .project)?.logs.maxAgeDays, 14)
    XCTAssertEqual(config.policy(for: .project)?.results.state, .notConfigured)
    XCTAssertEqual(config.policy(for: .explicit), config.userPolicy)
  }

  func testProjectWithoutPolicyInheritsUserPolicy() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"maxAgeDays":30}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let config = try load(home: home, project: project)

    XCTAssertEqual(config.projectPolicy, config.userPolicy)
  }

  func testEnvironmentPolicyOverridesFilesForBothTargets() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"maxAgeDays":30}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent("project", isDirectory: true)
    try writeConfiguration(#"{"retention":{"logs":{"maxAgeDays":10}}}"#, in: project)
    let environment = ["RIELA_RETENTION": #"{"results":{"maxAgeDays":7}}"#]

    let config = try load(home: home, project: project, environment: environment)

    XCTAssertEqual(config.userPolicy?.results.maxAgeDays, 7)
    XCTAssertEqual(config.projectPolicy, config.userPolicy)
  }

  func testEnvironmentFilesStillRejectRemovedKey() throws {
    let home = try makeRoot(configuration: #"{"gc":{}}"#)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertThrowsError(try load(home: home, environment: ["RIELA_RETENTION": #"{"results":{}}"#]))
  }

  func testAutomaticEnvironmentOverrideAndValidation() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"maxAgeDays":1}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }

    let config = try load(home: home, environment: ["RIELA_RETENTION_AUTOMATIC": "FALSE"])
    XCTAssertFalse(config.userPolicy?.automatic ?? true)
    XCTAssertThrowsError(try load(home: home, environment: ["RIELA_RETENTION_AUTOMATIC": "maybe"]))
  }

  func testAutomaticEnvironmentDoesNotCreatePolicy() throws {
    let home = try makeRoot()
    defer { try? FileManager.default.removeItem(at: home) }
    let config = try load(home: home, environment: ["RIELA_RETENTION_AUTOMATIC": "0"])
    XCTAssertNil(config.userPolicy)
    XCTAssertNil(config.projectPolicy)
  }

  func testUnknownTopLevelKeyIsIgnored() throws {
    let home = try makeRoot(configuration: #"{"theme":"x"}"#)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertNil(try load(home: home).userPolicy)
  }

  func testJSONBooleansAreNotAcceptedAsIntegers() throws {
    let home = try makeRoot(configuration: #"{"retention":{"results":{"maxAgeDays":true}}}"#)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertThrowsError(try load(home: home))
  }

  func testInactiveReportRoundTripsThroughJSON() throws {
    let report = RetentionCategoryReport.inactive(.keepForever)
    let decoded = try JSONDecoder().decode(RetentionCategoryReport.self, from: JSONEncoder().encode(report))
    XCTAssertEqual(decoded, report)
  }

  private func load(
    home: URL,
    project: URL? = nil,
    environment: [String: String] = [:]
  ) throws -> RielaRetentionConfiguration {
    try RielaRetentionConfiguration.load(
      homeDirectory: home,
      projectDirectory: project,
      environment: environment
    )
  }

  private func makeRoot(configuration: String? = nil) throws -> URL {
    let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let temporaryRoot = repositoryRoot.appendingPathComponent("tmp/automatic-retention-config-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let root = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true).standardizedFileURL
    let resolved = root.resolvingSymlinksInPath()
    XCTAssertTrue(resolved.path.hasPrefix(temporaryRoot.resolvingSymlinksInPath().path))
    try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
    if let configuration { try writeConfiguration(configuration, in: resolved) }
    return resolved
  }

  private func writeConfiguration(_ json: String, in root: URL) throws {
    let url = root.appendingPathComponent(".riela/config.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
  }
}
