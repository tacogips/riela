#if os(macOS)
import AppKit

enum RielaAppIcon {
  static func railTemplateImage() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()

    NSColor.black.setStroke()
    // Converging rails keep the silhouette recognizable at menu-bar size.
    let rails = NSBezierPath()
    rails.lineWidth = 1.8
    rails.lineCapStyle = .square
    rails.move(to: NSPoint(x: 4, y: 2.5))
    rails.line(to: NSPoint(x: 7, y: 15.5))
    rails.move(to: NSPoint(x: 14, y: 2.5))
    rails.line(to: NSPoint(x: 11, y: 15.5))
    rails.stroke()

    NSColor.black.setFill()
    for sleeper in [
      NSRect(x: 2.5, y: 4, width: 13, height: 1.5),
      NSRect(x: 3.5, y: 8, width: 11, height: 1.5),
      NSRect(x: 4.5, y: 12, width: 9, height: 1.5)
    ] {
      NSBezierPath(rect: sleeper).fill()
    }

    image.unlockFocus()
    image.isTemplate = true
    return image
  }
}
#endif
