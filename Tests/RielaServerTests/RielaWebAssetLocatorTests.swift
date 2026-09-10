import Foundation
import RielaServer
import XCTest

final class RielaWebAssetLocatorTests: XCTestCase {
  func testFindsInstalledFormulaAssetsThroughBinarySymlink() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let prefix = root.appendingPathComponent("Cellar/riela/1.0")
    let binary = prefix.appendingPathComponent("bin/riela")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: binary)
    let linked = root.appendingPathComponent("riela")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: binary)
    let assets = try makeAssets(at: prefix.appendingPathComponent("share/riela/web"))
    XCTAssertEqual(RielaWebAssetLocator.locate(bundle: nil, executableURL: linked, currentDirectoryURL: root)?.path, assets.path)
  }

  func testFindsCaskSiblingAssetsAndNativeBundleAssets() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let cask = try makeAssets(at: root.appendingPathComponent("Web"))
    XCTAssertEqual(RielaWebAssetLocator.locate(bundle: nil, executableURL: root.appendingPathComponent("riela"),
      currentDirectoryURL: root)?.path, cask.path)
    let native = try makeAssets(at: root.appendingPathComponent("App.app/Contents/Resources/Web"))
    XCTAssertEqual(RielaWebAssetLocator.locate(bundle: nil,
      executableURL: root.appendingPathComponent("App.app/Contents/MacOS/RielaApp"), currentDirectoryURL: root)?.path, native.path)
  }

  func testSkipsInvalidInstalledIndexAndUsesDevelopmentFallback() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid = root.appendingPathComponent("Web")
    try FileManager.default.createDirectory(at: invalid.appendingPathComponent("index.html"), withIntermediateDirectories: true)
    let development = try makeAssets(at: root.appendingPathComponent("project/web/dist"))
    let binary = root.appendingPathComponent("riela")
    XCTAssertEqual(RielaWebAssetLocator.locate(bundle: nil, executableURL: binary, currentDirectoryURL: root.appendingPathComponent("project"))?.path, development.path)
    try FileManager.default.removeItem(at: invalid.appendingPathComponent("index.html"))
    try FileManager.default.createSymbolicLink(at: invalid.appendingPathComponent("index.html"),
      withDestinationURL: development.appendingPathComponent("index.html"))
    XCTAssertEqual(RielaWebAssetLocator.locate(bundle: nil, executableURL: binary, currentDirectoryURL: root.appendingPathComponent("project"))?.path, development.path)
    try FileManager.default.removeItem(at: development)
    XCTAssertNil(RielaWebAssetLocator.locate(bundle: nil, executableURL: binary, currentDirectoryURL: root.appendingPathComponent("project")))
  }

  private func makeAssets(at url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("<!doctype html>".utf8).write(to: url.appendingPathComponent("index.html"))
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func fixtureRoot() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/web-asset-locator/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
