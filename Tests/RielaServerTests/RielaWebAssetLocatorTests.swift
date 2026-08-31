import Foundation
@testable import RielaServer
import XCTest

final class RielaWebAssetLocatorTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDownWithError() throws {
    for root in roots {
      try? FileManager.default.removeItem(at: root)
    }
    roots = []
  }

  /// A unique scratch directory removed in `tearDown`.
  private func makeTempTree() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-web-asset-locator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root.resolvingSymlinksInPath().standardizedFileURL
  }

  private func touch(_ url: URL, contents: String = "x") throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }

  /// Homebrew links `<prefix>/bin/riela` to `../Cellar/riela/<version>/bin/riela`, and
  /// `Bundle.main.executableURL` reports that symlink, so the locator has to resolve it
  /// before looking for `../share/riela/web`.
  func testSymlinkedExecutableResolvesToInstalledShareLayout() throws {
    let tree = try makeTempTree()
    let cellarBinary = tree.appendingPathComponent("cellar/bin/riela", isDirectory: false)
    let installedWeb = tree.appendingPathComponent("cellar/share/riela/web", isDirectory: true)
    let link = tree.appendingPathComponent("link/riela", isDirectory: false)
    let cwd = tree.appendingPathComponent("cwd", isDirectory: true)
    try touch(cellarBinary, contents: "#!/bin/sh\n")
    try touch(installedWeb.appendingPathComponent("index.html", isDirectory: false), contents: "<main>ok</main>")
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../cellar/bin/riela")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    // Without symlink resolution the locator would look beside the link, where nothing exists.
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: tree.appendingPathComponent("link/../share/riela/web/index.html").standardizedFileURL.path
      )
    )

    let located = RielaWebAssetLocator.locate(
      bundle: nil,
      executableURL: link,
      currentDirectoryURL: cwd
    )
    XCTAssertEqual(located?.standardizedFileURL.path, installedWeb.standardizedFileURL.path)
  }

  func testResourcesWebWinsOverShareAndCwd() throws {
    let tree = try makeTempTree()
    let executable = tree.appendingPathComponent("prefix/bin/riela", isDirectory: false)
    let resourcesWeb = tree.appendingPathComponent("prefix/Resources/Web", isDirectory: true)
    let shareWeb = tree.appendingPathComponent("prefix/share/riela/web", isDirectory: true)
    let cwd = tree.appendingPathComponent("cwd", isDirectory: true)
    let cwdWeb = cwd.appendingPathComponent("web/dist", isDirectory: true)
    try touch(executable)
    try touch(resourcesWeb.appendingPathComponent("index.html", isDirectory: false))
    try touch(shareWeb.appendingPathComponent("index.html", isDirectory: false))
    try touch(cwdWeb.appendingPathComponent("index.html", isDirectory: false))

    func locate() -> URL? {
      RielaWebAssetLocator.locate(bundle: nil, executableURL: executable, currentDirectoryURL: cwd)
    }

    XCTAssertEqual(locate()?.standardizedFileURL.path, resourcesWeb.standardizedFileURL.path)
    try FileManager.default.removeItem(at: resourcesWeb)
    XCTAssertEqual(locate()?.standardizedFileURL.path, shareWeb.standardizedFileURL.path)
    try FileManager.default.removeItem(at: shareWeb)
    XCTAssertEqual(locate()?.standardizedFileURL.path, cwdWeb.standardizedFileURL.path)
  }

  func testShareLayoutFoundForDirectInvocation() throws {
    let tree = try makeTempTree()
    let executable = tree.appendingPathComponent("prefix/bin/riela", isDirectory: false)
    let shareWeb = tree.appendingPathComponent("prefix/share/riela/web", isDirectory: true)
    let cwd = tree.appendingPathComponent("cwd", isDirectory: true)
    try touch(executable)
    try touch(shareWeb.appendingPathComponent("index.html", isDirectory: false))
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    XCTAssertEqual(
      RielaWebAssetLocator.locate(bundle: nil, executableURL: executable, currentDirectoryURL: cwd)?
        .standardizedFileURL.path,
      shareWeb.standardizedFileURL.path
    )
  }

  func testFallsBackToCurrentDirectoryWebDist() throws {
    let tree = try makeTempTree()
    let executable = tree.appendingPathComponent("prefix/bin/riela", isDirectory: false)
    let cwd = tree.appendingPathComponent("cwd", isDirectory: true)
    let cwdWeb = cwd.appendingPathComponent("web/dist", isDirectory: true)
    try touch(executable)
    try touch(cwdWeb.appendingPathComponent("index.html", isDirectory: false))

    XCTAssertEqual(
      RielaWebAssetLocator.locate(bundle: nil, executableURL: executable, currentDirectoryURL: cwd)?
        .standardizedFileURL.path,
      cwdWeb.standardizedFileURL.path
    )
  }

  func testReturnsNilWhenNothingHasIndex() throws {
    let tree = try makeTempTree()
    let executable = tree.appendingPathComponent("prefix/bin/riela", isDirectory: false)
    let cwd = tree.appendingPathComponent("cwd", isDirectory: true)
    try touch(executable)
    // A share directory without index.html must not be accepted.
    try FileManager.default.createDirectory(
      at: tree.appendingPathComponent("prefix/share/riela/web", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    XCTAssertNil(
      RielaWebAssetLocator.locate(bundle: nil, executableURL: executable, currentDirectoryURL: cwd)
    )
    XCTAssertNil(
      RielaWebAssetLocator.locate(bundle: nil, executableURL: nil, currentDirectoryURL: cwd)
    )
  }

  func testCandidatesOrderIsStable() throws {
    let tree = try makeTempTree()
    let executable = tree.appendingPathComponent("prefix/bin/riela", isDirectory: false)
    let cwd = tree.appendingPathComponent("cwd", isDirectory: true)
    try touch(executable)

    let candidates = RielaWebAssetLocator.candidates(
      bundle: nil,
      executableURL: executable,
      currentDirectoryURL: cwd
    )
    XCTAssertEqual(
      candidates.map { $0.standardizedFileURL.path },
      [
        tree.appendingPathComponent("prefix/Resources/Web").standardizedFileURL.path,
        tree.appendingPathComponent("prefix/share/riela/web").standardizedFileURL.path,
        cwd.appendingPathComponent("web/dist").standardizedFileURL.path
      ]
    )
    XCTAssertEqual(RielaWebAssetLocator.executableRelativeCandidates, ["../Resources/Web", "../share/riela/web"])
  }
}
