#if os(macOS)
import AppKit

@MainActor
enum RielaAppIcon {
  private static let rail: NSImage = {
    // SwiftPM's generated accessor searches beside the executable or in the
    // build tree. Distributed macOS bundles stage resources in Contents/Resources.
    let resources = packagedResources(in: .main) ?? Bundle.module
    guard let url = resources.url(forResource: "RielaLogo", withExtension: "png"),
      let image = RielaBrandImage.rail(from: url) else {
      preconditionFailure("Missing bundled Riela logo")
    }
    return image
  }()

  static func packagedResources(in application: Bundle) -> Bundle? {
    application.url(forResource: "riela_RielaApp", withExtension: "bundle").flatMap(Bundle.init(url:))
  }

  static func railTemplateImage(size: NSSize = NSSize(width: 22, height: 14)) -> NSImage {
    guard let image = rail.copy() as? NSImage else { preconditionFailure("Cannot copy Riela rail image") }
    image.size = size
    image.isTemplate = true
    return image
  }

  static func appIcon() -> NSImage {
    RielaBrandImage.appIcon(rail: rail)
  }
}
#endif
