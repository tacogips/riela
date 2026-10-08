import AppKit

/// Invoked by render-riela-brand-assets.sh to keep all app surfaces in sync.
@main
@MainActor
enum RenderRielaBrandAssets {
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let logo = root.appendingPathComponent("img/riela.png")
    guard let rail = RielaBrandImage.rail(from: logo) else { throw CocoaError(.fileReadCorruptFile) }
    let icon = RielaBrandImage.appIcon(rail: rail)
    try save(rail, to: root.appendingPathComponent("web/public/riela-rail.png"))
    try save(icon, to: root.appendingPathComponent("img/riela_icon.png"))
    try save(icon, to: root.appendingPathComponent("web/src-tauri/icons/icon.png"))
    let bundledLogo = root.appendingPathComponent("Sources/RielaApp/Resources/RielaLogo.png")
    try Data(contentsOf: logo).write(to: bundledLogo, options: .atomic)
  }

  private static func save(_ image: NSImage, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width),
      pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(origin: .zero, size: image.size))
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url, options: .atomic)
  }
}
