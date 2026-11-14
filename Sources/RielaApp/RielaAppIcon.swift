#if os(macOS)
import AppKit

enum RielaAppIcon {
  static func workflowTemplateImage() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()

    NSColor.black.setStroke()
    let edgePath = NSBezierPath()
    edgePath.lineWidth = 1.8
    edgePath.lineCapStyle = .round
    edgePath.lineJoinStyle = .round
    edgePath.move(to: NSPoint(x: 5, y: 9))
    edgePath.line(to: NSPoint(x: 9, y: 13))
    edgePath.line(to: NSPoint(x: 13, y: 13))
    edgePath.move(to: NSPoint(x: 5, y: 9))
    edgePath.line(to: NSPoint(x: 9, y: 5))
    edgePath.line(to: NSPoint(x: 13, y: 5))
    edgePath.stroke()

    NSColor.black.setFill()
    for center in [
      NSPoint(x: 5, y: 9),
      NSPoint(x: 13, y: 13),
      NSPoint(x: 13, y: 5)
    ] {
      NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
    }

    image.unlockFocus()
    image.isTemplate = true
    return image
  }
}
#endif
