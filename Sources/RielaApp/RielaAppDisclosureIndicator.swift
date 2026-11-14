#if os(macOS)
import AppKit

@MainActor
func rielaAppDisclosureIndicator() -> NSImageView {
  let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
  let imageView = NSImageView(image: image ?? NSImage())
  imageView.translatesAutoresizingMaskIntoConstraints = false
  imageView.imageScaling = .scaleProportionallyDown
  imageView.contentTintColor = .tertiaryLabelColor
  imageView.setAccessibilityElement(false)
  NSLayoutConstraint.activate([
    imageView.widthAnchor.constraint(equalToConstant: 10),
    imageView.heightAnchor.constraint(equalToConstant: 12)
  ])
  return imageView
}
#endif
