import Foundation
import XCTest
@testable import RielaCLI

final class SubcommandHelpApplicationTests: XCTestCase {
  private struct HelpThrowingParser: CLIArgumentParsing {
    func parse(_ arguments: [String]) throws -> RielaCommand {
      _ = try ParsedWorkflowRegisterArguments.parseCLI(["--help"])
      return .help
    }
  }

  func testSubcommandHelpPrintsUsageBeforeArgumentValidation() async {
    let cases: [([String], String)] = [
      (["storage", "compact", "--help"], "riela storage compact [--apply]"),
      (["storage", "compact", "-h"], "riela storage compact [--apply]"),
      (["storage", "compact", "--help", "--output", "json"], "riela storage compact [--apply]"),
      (["doctor", "storage", "--help"], "riela doctor storage"),
      (["session", "status", "--help"], "riela session status|continue|step-runs|export|logs <session-id>"),
      (["session", "resume", "-h"], "riela session resume <session-id>"),
      (["workflow", "validate", "--help"], "riela workflow validate <workflow>"),
      (["workflow", "inspect", "--help"], "riela workflow inspect"),
      (["workflow", "delete", "--help"], "riela workflow delete"),
      (["loop", "start", "--help"], "riela loop start <workflow>"),
      (["workflow", "run", "demo", "--help"], "Riela workflow run"),
      (["workflow", "--help"], "workflow register")
    ]
    for (arguments, expected) in cases {
      let result = await RielaCLIApplication().run(arguments)
      XCTAssertEqual(result.exitCode, .success, "\(arguments): \(result.stderr)")
      XCTAssertEqual(result.stderr, "", "\(arguments)")
      XCTAssertTrue(result.stdout.contains(expected), "\(arguments): \(result.stdout)")
      XCTAssertFalse(result.stdout.contains("helpRequested"), "\(arguments)")
      XCTAssertFalse(result.stdout.contains("\"error\""), "\(arguments)")
      XCTAssertFalse(result.stdout.contains("requires a"), "\(arguments)")
    }
    let workflow = await RielaCLIApplication().run(["workflow", "--help"])
    XCTAssertTrue(workflow.stdout.contains("--exclude-mutable"))
  }

  func testTopLevelAndDelegatedHelpStayUnchanged() async {
    let top = await RielaCLIApplication().run(["--help"])
    XCTAssertEqual(top.exitCode, .success)
    XCTAssertEqual(top.stdout, rielaCLIHelpText)
    for arguments in [
      ["gc", "--help"], ["gc", "-h"],
      ["session", "prune", "--help"], ["session", "prune", "-h"],
      ["session", "reconcile", "--help"], ["session", "reconcile", "-h"],
      ["cache", "put", "--help"], ["cache", "put", "-h"],
      ["environment", "status", "--help"], ["environment", "status", "-h"],
      ["environment", "reload", "--help"]
    ] {
      let result = await RielaCLIApplication().run(arguments)
      XCTAssertEqual(result.exitCode, .success, "\(arguments): \(result.stderr)")
      XCTAssertFalse(result.stdout.isEmpty, "\(arguments)")
      XCTAssertFalse(result.stdout.contains("helpRequested"), "\(arguments)")
      XCTAssertFalse(result.stdout.hasPrefix("{\"error\""), "\(arguments)")
    }
  }

  func testAuthInviteHelpDoesNotCreateInvitation() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/passkey-auth/help/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["HOME": root.path, "RIELA_WEB_AUTH_ROOT": root.appendingPathComponent("auth").path,
      "RIELA_WEB_ORIGIN": "https://riela.example"]
    let app = RielaCLIApplication()
    let help = await app.run(["auth", "invite", "--help"], environment: environment)
    XCTAssertEqual(help.exitCode, .success)
    XCTAssertTrue(help.stdout.contains("Passkey"))
    let users = await app.run(["auth", "users"], environment: environment)
    XCTAssertFalse(users.stdout.contains("--help"))
  }

  func testParseCLIRethrowsCleanExitAndWrapsUsageErrors() {
    XCTAssertThrowsError(try ParsedWorkflowRegisterArguments.parseCLI(["--help"])) { error in
      XCTAssertTrue(CLISubcommandHelp.isCleanExit(error))
    }
    XCTAssertThrowsError(try ParsedWorkflowRegisterArguments.parseCLI(["--bogus"])) { error in
      XCTAssertTrue(error is CLIUsageError)
    }
  }

  func testFinalCatchMapsCleanExitToUsage() async {
    let app = RielaCLIApplication(parser: HelpThrowingParser())
    let status = await app.run(["workflow", "status"])
    XCTAssertEqual(status.exitCode, .success)
    XCTAssertTrue(status.stdout.contains("riela workflow status <workflow>"), status.stdout)
    let unknown = await app.run(["bogus"])
    XCTAssertEqual(unknown.exitCode, .success)
    XCTAssertEqual(unknown.stdout, rielaCLIHelpText)
  }
}
