#if os(macOS)
import AppKit

@MainActor
enum RielaAppIcon {
  private static let rail: NSImage = {
    guard let url = Bundle.module.url(forResource: "RielaLogo", withExtension: "png"),
      let image = RielaBrandImage.rail(from: url) else {
      preconditionFailure("Missing bundled Riela logo")
    }
    return image
  }()

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
