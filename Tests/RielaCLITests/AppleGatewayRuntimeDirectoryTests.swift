import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleGatewayRuntimeDirectoryTests: XCTestCase {
  func testProjectRuntimeDirectoryRetainsOwnerAndSymlinkGuards() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/apple-runtime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent(".runtime/downloads")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let downloader = AppleGatewayFileDownloader(
      runner: AppleGatewayInvoker(runtimeEnvironment: [:], runnerOverride: { _, _, _ in
        XCTFail("Path validation must not invoke the gateway")
        return AppleGatewayProcessOutput(stdout: "", stderr: "", terminationStatus: 0)
      }), currentDirectory: root
    )
    XCTAssertEqual(try downloader.validatedOutputRootPath(target.path, label: "downloadDir"), target.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    XCTAssertThrowsError(try downloader.validatedOutputRootPath(target.path, label: "downloadDir"))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    let link = root.appendingPathComponent(".runtime/link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    XCTAssertThrowsError(try downloader.validatedOutputRootPath(link.path, label: "downloadDir"))
    let publicPath = root.appendingPathComponent("public/downloads")
    try FileManager.default.createDirectory(at: publicPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    XCTAssertThrowsError(try downloader.validatedOutputRootPath(publicPath.path, label: "downloadDir"))
  }
}
