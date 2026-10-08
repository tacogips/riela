#if os(macOS)
import AppKit
import XCTest
@testable import RielaApp

@MainActor
final class RielaAppBrandingTests: XCTestCase {
  func testPackagedResourcesResolveInsideAppInsteadOfBuildTree() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/branding-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("RielaApp.app")
    let resources = app.appendingPathComponent("Contents/Resources/riela_RielaApp.bundle")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist = ["CFBundleIdentifier": "test.riela.branding", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let application = try XCTUnwrap(Bundle(url: app))
    let packaged = try XCTUnwrap(RielaAppIcon.packagedResources(in: application))
    XCTAssertEqual(packaged.bundleURL.standardizedFileURL.path, resources.standardizedFileURL.path)
  }

  func testBundledLogoProducesIndependentTemplateImages() throws {
    let menu = RielaAppIcon.railTemplateImage()
    let header = RielaAppIcon.railTemplateImage(size: NSSize(width: 36, height: 23))
    XCTAssertTrue(menu.isTemplate)
    XCTAssertTrue(header.isTemplate)
    XCTAssertEqual(menu.size, NSSize(width: 22, height: 14))
    XCTAssertEqual(header.size, NSSize(width: 36, height: 23))
    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(menu.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    XCTAssertTrue(bitmap.hasAlpha, "Menu bar background must remain transparent in both appearances")
    XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
  }

  func testApplicationIconHasSquareCanvasAndTransparentCorners() throws {
    let icon = RielaAppIcon.appIcon()
    XCTAssertFalse(icon.isTemplate)
    XCTAssertEqual(icon.size, NSSize(width: 1024, height: 1024))
    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(icon.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
    XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent, 0.99)
  }
}
#endif
