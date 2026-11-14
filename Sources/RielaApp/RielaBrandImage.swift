#if os(macOS)
import AppKit
import CoreImage
import ImageIO

/// Use the README artwork itself, preserving its rails, sleepers and perspective.
@MainActor
enum RielaBrandImage {
  static func rail(from logoURL: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(logoURL as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let crop = logo.cropping(to: CGRect(x: 410, y: 258, width: 422, height: 267)) else { return nil }
    let mask = CIImage(cgImage: crop)
      .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.05, "inputBrightness": -0.025])
      .applyingFilter("CIMaskToAlpha")
    guard let image = CIContext().createCGImage(mask, from: mask.extent) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: 422, height: 267))
  }

  static func appIcon(rail: NSImage) -> NSImage {
    NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
      let width: CGFloat = 728
      let height = width * rail.size.height / rail.size.width
      rail.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2, width: width, height: height))
      return true
    }
  }
}
#endif
