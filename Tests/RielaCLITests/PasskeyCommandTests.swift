import Foundation
import XCTest
@testable import RielaCLI

final class PasskeyCommandTests: XCTestCase {
  func testInviteListRevokeAndHelpUseIsolatedServerStore() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/passkey-auth/cli/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["HOME": root.path, "RIELA_WEB_AUTH_ROOT": root.appendingPathComponent("auth").path,
      "RIELA_WEB_ORIGIN": "https://riela.example"]
    let app = RielaCLIApplication()
    let help = await app.run(["auth", "--help"], environment: environment)
    XCTAssertEqual(help.exitCode, .success)
    XCTAssertTrue(help.stdout.contains("Passkey"))
    let invited = await app.run(["auth", "invite", "operator"], environment: environment)
    XCTAssertEqual(invited.exitCode, .success, invited.stderr)
    XCTAssertTrue(invited.stdout.hasPrefix("https://riela.example/#/auth/register/"))
    let second = await app.run(["auth", "invite", "operator"], environment: environment)
    XCTAssertEqual(second.exitCode, .success)
    XCTAssertNotEqual(second.stdout, invited.stdout)
    let listing = await app.run(["auth", "users"], environment: environment)
    let users = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listing.stdout.utf8)) as? [[String: Any]])
    XCTAssertEqual(users.count, 1)
    XCTAssertEqual(users.first?["name"] as? String, "operator")
    XCTAssertFalse(listing.stdout.contains("invitations"))
    let revoked = await app.run(["auth", "revoke-user", "operator"], environment: environment)
    XCTAssertEqual(revoked.exitCode, .success)
    let disabled = await app.run(["auth", "invite", "operator"], environment: environment)
    XCTAssertEqual(disabled.exitCode, .failure)
    let missing = await app.run(["auth", "revoke-key", "does-not-exist"], environment: environment)
    XCTAssertEqual(missing.exitCode, .failure)
    let invalid = await app.run(["auth", "invite", "user", "--unexpected"], environment: environment)
    XCTAssertEqual(invalid.exitCode, .usage)
  }
}
