import ArgumentParser
import XCTest
@testable import RielaCLI

final class SubcommandHelpTests: XCTestCase {
  func testDetection() {
    let cases: [([String], CLIHelpRequest)] = [
      (["storage", "compact", "--help"], CLIHelpRequest(path: ["storage", "compact"], runTarget: nil)),
      (["storage", "compact", "-h"], CLIHelpRequest(path: ["storage", "compact"], runTarget: nil)),
      (["session", "status", "--help"], CLIHelpRequest(path: ["session", "status"], runTarget: nil)),
      (["workflow", "validate", "--help"], CLIHelpRequest(path: ["workflow", "validate"], runTarget: nil)),
      (["workflow", "run", "demo", "--help"], CLIHelpRequest(path: ["workflow", "run"], runTarget: "demo")),
      (["workflow", "run", "--help"], CLIHelpRequest(path: ["workflow", "run"], runTarget: nil)),
      (["session", "--help"], CLIHelpRequest(path: ["session"], runTarget: nil)),
      (["workflow", "--help"], CLIHelpRequest(path: ["workflow"], runTarget: nil)),
      (["serve", "--help"], CLIHelpRequest(path: ["serve"], runTarget: nil)),
      (["auth", "invite", "--help"], CLIHelpRequest(path: ["auth", "invite"], runTarget: nil)),
      (["workflow", "run", "demo", "--message", "--help"], CLIHelpRequest(path: ["workflow", "run"], runTarget: "demo")),
      (["gateway", "list", "--help"], CLIHelpRequest(path: ["gateway", "list"], runTarget: nil))
    ]
    for (arguments, expected) in cases {
      XCTAssertEqual(CLIHelpRequest.detect(arguments), expected, "\(arguments)")
    }
    let ignored = [
      [], ["--help"], ["-h"], ["bogus", "--help"],
      ["sandbox", "run", "--backend", "auto", "--", "prog", "--help"],
      ["gateway", "gmail", "--help"], ["gateway", "unknown", "--help"], ["gc", "--help"],
      ["session", "prune", "--help"], ["session", "reconcile", "-h"],
      ["cache", "put", "--help"], ["environment", "status", "-h"],
      ["workflow", "validate", "demo"], ["workflow", "run", "demo", "--message=--help"],
      ["workflow", "-help"], ["workflow", "help"], ["workflow", "--help=x"]
    ]
    for arguments in ignored { XCTAssertNil(CLIHelpRequest.detect(arguments), "\(arguments)") }
    XCTAssertEqual(CLIHelpRequest.resolve(["workflow", "run", "demo", "--", "x"])?.runTarget, "demo")
  }

  func testUsageSlices() {
    let storage = CLISubcommandHelp.result(path: ["storage", "compact"])
    XCTAssertEqual(storage.exitCode, .success)
    XCTAssertEqual(storage.stderr, "")
    XCTAssertTrue(storage.stdout.hasPrefix("Usage:\n"))
    XCTAssertTrue(storage.stdout.contains("riela storage compact [--apply] [--max-batch <n>] [--abandoned-after-hours <h>] [--allow-live-vacuum] [--output text|json]"))
    XCTAssertFalse(storage.stdout.contains("riela doctor storage"))
    let session = CLISubcommandHelp.result(path: ["session", "status"]).stdout
    XCTAssertTrue(session.contains("riela session status|continue|step-runs|export|logs <session-id> [options]"))
    XCTAssertFalse(session.contains("riela session list"))
    XCTAssertTrue(CLISubcommandHelp.result(path: ["workflow", "validate"]).stdout.contains("riela workflow validate <workflow>"))
    let version = CLISubcommandHelp.result(path: ["workflow", "version"]).stdout
    XCTAssertTrue(version.contains("riela workflow version show"))
    XCTAssertTrue(version.contains("riela workflow version diff"))
    XCTAssertFalse(version.contains("riela workflow versions"))
    let gc = CLISubcommandHelp.result(path: ["gc"]).stdout
    XCTAssertTrue(gc.contains("riela gc [--scope"))
    XCTAssertTrue(gc.contains("[--messages-max-age-days N]"))
    XCTAssertTrue(CLISubcommandHelp.result(path: ["node", "run"]).stdout.contains("[--sandbox auto|container|seatbelt|bubblewrap]"))
    XCTAssertTrue(CLISubcommandHelp.result(path: ["events", "validate"]).stdout.contains("riela graphql|gql|hook|events|serve|call-step|workflow-call"))
    XCTAssertEqual(CLISubcommandHelp.result(path: ["kaiba", "instance", "list"]).stdout, rielaCLIHelpText)
    let workflow = CLISubcommandHelp.result(path: ["workflow"]).stdout
    XCTAssertTrue(workflow.contains("workflow register"))
    XCTAssertTrue(workflow.contains("--exclude-mutable"))
    XCTAssertFalse(workflow.contains("Leading-dash values"))
  }

  func testDedicatedSources() {
    let request = CLIHelpRequest(path: ["workflow", "run"], runTarget: "demo")
    XCTAssertEqual(CLISubcommandHelp.result(for: request).stdout, workflowRunHelpText(target: "demo"))
    XCTAssertEqual(CLISubcommandHelp.result(path: ["workflow", "register"]).stdout, workflowRegisterHelpText)
    XCTAssertEqual(CLISubcommandHelp.result(path: ["package", "install"]).stdout, packageHelpText(scope: .package))
    XCTAssertEqual(CLISubcommandHelp.result(path: ["workflow", "package", "install"]).stdout, packageHelpText(scope: .workflowPackage))
    XCTAssertEqual(CLISubcommandHelp.result(path: ["auth", "invite"]).stdout, PasskeyCommand.help + "\n")
    XCTAssertEqual(CLISubcommandHelp.result(path: ["sandbox", "run"]).stdout, SandboxCommand.helpText)
    XCTAssertEqual(CLISubcommandHelp.result(path: ["worker"]).stdout, DistributedWorkerCommand.helpText)
    XCTAssertEqual(CLISubcommandHelp.result(path: ["gateway", "list"]).stdout, GatewayCommand.help)
  }

  func testSurfaceAudit() {
    var count = 0
    for descriptor in CLISurfaceEnumerator.commands() {
      let path = descriptor.path
      if path == ["gc"] || path == ["session", "prune"] || path == ["session", "reconcile"]
        || path.first == "cache" || path.first == "environment"
        || (path.first == "gateway" && path.count > 1 && path[1] != "list") { continue }
      count += 1
      for flag in ["--help", "-h"] {
        guard let request = CLIHelpRequest.detect(path + [flag]) else {
          XCTFail("Missing help for \(path) \(flag)")
          continue
        }
        let result = CLISubcommandHelp.result(for: request)
        XCTAssertEqual(result.exitCode, .success, "\(path)")
        XCTAssertEqual(result.stderr, "", "\(path)")
        XCTAssertFalse(result.stdout.isEmpty, "\(path)")
        XCTAssertFalse(result.stdout.contains("helpRequested"), "\(path)")
        XCTAssertFalse(result.stdout.hasPrefix("{\"error\""), "\(path)")
      }
    }
    print("Subcommand help audited paths: \(count)")
    XCTAssertGreaterThanOrEqual(count, 50)
  }

  func testCleanExit() {
    XCTAssertFalse(CLISubcommandHelp.isCleanExit(CLIUsageError("x")))
    XCTAssertTrue(CLISubcommandHelp.isCleanExit(CleanExit.helpRequest()))
    for flag in ["--help", "-h", "-help"] {
      do {
        _ = try ParsedStorageCommandArguments.parse([flag])
        XCTFail("Expected a help error for \(flag)")
      } catch {
        XCTAssertTrue(CLISubcommandHelp.isCleanExit(error), "\(flag): \(error)")
      }
    }
    do {
      _ = try ParsedStorageCommandArguments.parse(["--definitely-unknown-option"])
      XCTFail("Expected an unknown option error")
    } catch {
      XCTAssertFalse(CLISubcommandHelp.isCleanExit(error))
    }
  }
}
