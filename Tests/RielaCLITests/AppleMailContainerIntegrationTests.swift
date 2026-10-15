import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleMailContainerIntegrationTests: XCTestCase {
  func testRealNativeFileStoreFailureDoesNotBecomeSuccessfulDownload() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("native-file-store-error")
    defer { try? FileManager.default.removeItem(at: root) }
    let hostHome = root.deletingLastPathComponent().appendingPathComponent("host-home-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: hostHome) }
    let environment = ["HOME": hostHome.path]
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: BuiltinWorkflowAddonResolver(environment: environment, workingDirectory: root), environment: environment, workingDirectory: root)
    do {
      _ = try await NativeAddonPinnedDirectory.StagingContext.$root.withValue(root.deletingLastPathComponent()) {
        try await resolver.execute(input("riela/apple-gateway-file-download", config: ["keys": .array([.string("invalid-fixture-key")]), "outputDir": .string(root.appendingPathComponent("tmp/downloads").path)]),
          context: .init(deadline: Date().addingTimeInterval(120)))
      }
      XCTFail("the real SDK must reject an invalid download key")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("INVALID_DOWNLOAD_KEY"), error.message)
    }
  }

  func testDefaultDownloadDestinationIsGuestWorkspace() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("default-download-guest")
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root), environment: [:], workingDirectory: root,
      nativeAppleGatewayRunner: { arguments, _, _ in
        XCTAssertEqual(Array(arguments.prefix(5)), ["file", "download", "--key", "fixture", "--output-dir"])
        let file = URL(fileURLWithPath: arguments[5]).appendingPathComponent("fixture.txt")
        try "download".write(to: file, atomically: true, encoding: .utf8)
        return .init(stdout: try mailContainerJSON(["files": .array([.object(["path": .string(file.path)])])]), stderr: "")
      })
    _ = try await NativeAddonPinnedDirectory.StagingContext.$root.withValue(root.deletingLastPathComponent()) {
      try await resolver.execute(input("riela/apple-gateway-file-download", config: ["keys": .string("fixture")]),
        context: .init(deadline: Date().addingTimeInterval(120)))
    }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tmp/apple-gateway/downloads/fixture.txt"), encoding: .utf8), "download")
  }

  func testMailListAndPermissionDenialPassThroughRealGuest() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("mail-list-guest")
    defer { try? FileManager.default.removeItem(at: root) }
    for authorized in [true, false] {
      let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
        primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root), environment: [:], workingDirectory: root,
        nativeAppleGatewayRunner: { _, _, _ in
          .init(stdout: try mailContainerJSON(["data": .object([
            "permissions": .object(["mailFullDiskAccess": .string(authorized ? "AUTHORIZED" : "DENIED")]),
            "mailAccounts": .array([]), "mailboxes": .array([]),
            "mailMessages": .object(["totalCount": .integer(0), "edges": .array([]),
              "pageInfo": .object(["hasNextPage": .bool(false), "endCursor": .null])])])]), stderr: "")
        })
      do {
        let output = try await resolver.execute(input("riela/apple-mail-list"), context: .init(deadline: Date().addingTimeInterval(120)))
        XCTAssertTrue(authorized)
        XCTAssertEqual(output.payload["messageCount"], .integer(0))
      } catch let error as AdapterExecutionError {
        XCTAssertFalse(authorized, error.message)
        XCTAssertEqual(error.code, .policyBlocked)
        XCTAssertTrue(error.message.contains("Full Disk Access"))
      }
    }
  }

  func testMailBodyHTMLRawAndAttachmentMaterializeThroughScopedHostStage() async throws {
    try requireImage()
    let root = try makeRielaCLITestTemporaryDirectory("mail-files-guest")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloads = root.appendingPathComponent("tmp/downloads")
    let contents = ["body": "body text", "html": "<p>body</p>", "raw": "Subject: fixture\r\n\r\nbody", "attachment": "attachment bytes"]
    let files: JSONObject = ["bodyText": descriptor("body", filename: "body.txt"),
      "bodyHtml": descriptor("html", filename: "body.html"), "rawSource": descriptor("raw", filename: "raw.eml"),
      "attachments": .array([descriptor("attachment", filename: "../attachment.txt")])]
    let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
      primary: BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root), environment: [:], workingDirectory: root,
      nativeAppleGatewayRunner: { arguments, _, _ in
        if arguments.first == "graphql" {
          return .init(stdout: try mailContainerJSON(["data": .object([
            "permissions": .object(["mailFullDiskAccess": .string("AUTHORIZED")]),
            "mailMessage": .object(["id": .string("fixture"), "files": .object(files)])])]), stderr: "")
        }
        guard arguments.count == 6, let content = contents[arguments[3]] else {
          throw AdapterExecutionError(.invalidInput, "unexpected fixture download")
        }
        let path = URL(fileURLWithPath: arguments[5]).appendingPathComponent("native-" + arguments[3])
        try Data(content.utf8).write(to: path, options: .withoutOverwriting)
        return .init(stdout: try mailContainerJSON(["files": .array([.object([
          "downloadKey": .string(arguments[3]), "path": .string(path.path)])])]), stderr: "")
      })
    let output = try await NativeAddonPinnedDirectory.StagingContext.$root.withValue(root.deletingLastPathComponent()) {
      try await resolver.execute(input("riela/apple-mail-message", config: ["messageId": .string("fixture"),
        "downloadDir": .string(downloads.path), "materializeBodyHtml": .bool(true), "materializeRawSource": .bool(true),
        "materializeAttachments": .bool(true)]), context: .init(deadline: Date().addingTimeInterval(120)))
    }
    guard case let .object(mail)? = output.payload["appleMail"], case let .array(materialized)? = mail["materialized"] else {
      return XCTFail("missing materialized Mail files")
    }
    let paths = materialized.compactMap { value -> String? in
      guard case let .object(file) = value, case let .string(path)? = file["localPath"] else { return nil }
      return path
    }
    XCTAssertEqual(paths.count, 4)
    XCTAssertTrue(paths.allSatisfy { $0.hasPrefix(downloads.path + "/") })
    XCTAssertEqual(Set(try paths.map { try String(contentsOfFile: $0, encoding: .utf8) }), Set(contents.values))
  }

  private func descriptor(_ key: String, filename: String) -> JSONValue {
    .object(["downloadKey": .string(key), "filename": .string(filename), "mimeType": .string("text/plain")])
  }

  private func input(_ name: String, config: JSONObject = [:]) -> WorkflowAddonExecutionInput {
    .init(workflowId: "fixture", stepId: "mail", nodeId: "mail", addon: .init(name: name, version: "1", config: config,
      container: .init(image: ProcessInfo.processInfo.environment["RIELA_TEST_BUILTIN_IMAGE"] ?? WorkflowAddonContainerExecution.defaultImage,
        runtime: .appleContainer, networkPolicy: .denied)))
  }

  private func requireImage() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RIELA_TEST_LIVE_BUILTIN_IMAGE"] == "1", "opt-in real guest Mail tests")
  }
}

private func mailContainerJSON(_ object: JSONObject) throws -> String {
  try XCTUnwrap(String(data: JSONEncoder().encode(JSONValue.object(object)), encoding: .utf8))
}
