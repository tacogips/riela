import XCTest
@testable import RielaCLI

final class StorageHelpBackstopTests: XCTestCase {
  func testCompactHelp() {
    for flag in ["--help", "-h"] {
      let result = StorageCompactCommandRunner().run(["compact", flag])
      XCTAssertEqual(result.exitCode, .success)
      XCTAssertEqual(result.stderr, "")
      XCTAssertTrue(result.stdout.contains("riela storage compact [--apply] [--max-batch <n>] [--abandoned-after-hours <h>] [--allow-live-vacuum] [--output text|json]"))
      XCTAssertFalse(result.stdout.contains("helpRequested"))
      XCTAssertFalse(result.stdout.contains("\"error\""))
    }
  }

  func testDoctorHelp() {
    let result = StorageDoctorCommandRunner().run(["--help"])
    XCTAssertEqual(result.exitCode, .success)
    XCTAssertEqual(result.stderr, "")
    XCTAssertTrue(result.stdout.contains("riela doctor storage"))
    XCTAssertFalse(result.stdout.contains("helpRequested"))
  }

  func testParserHelpErrorMapsToUsageForBothPaths() {
    do {
      _ = try ParsedStorageCommandArguments.parse(["--help"])
      XCTFail("Expected parser help error")
    } catch {
      for path in [["storage", "compact"], ["doctor", "storage"]] {
        let result = StorageCommandFailure.result(error, usagePath: path)
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("riela " + path.joined(separator: " ")))
        XCTAssertFalse(result.stdout.contains("\"error\""))
      }
    }
  }

  func testNonHelpErrorsRemainUsageJSON() {
    let top = StorageCompactCommandRunner().run(["compact", "--top", "3"])
    XCTAssertEqual(top.exitCode, .usage)
    XCTAssertTrue(top.stdout.hasPrefix("{\"error\""))
    XCTAssertEqual(StorageCompactCommandRunner().run(["compact", "--output", "yaml"]).exitCode, .usage)
    let error = StorageCommandFailure.result(CLIUsageError("x"), usagePath: ["storage", "compact"])
    XCTAssertEqual(error.exitCode, .usage)
    XCTAssertEqual(error.stdout, "{\"error\":\"x\"}\n")
  }
}
