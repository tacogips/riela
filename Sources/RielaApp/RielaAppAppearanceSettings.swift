#if os(macOS)
import AppKit
import RielaAppSupport

extension RielaAppColorScheme {
  var nsAppearanceName: NSAppearance.Name {
    switch self {
    case .dark:
      return .darkAqua
    case .light:
      return .aqua
    }
  }
}

@MainActor
func rielaAppApplyColorScheme(_ colorScheme: RielaAppColorScheme) {
  NSApplication.shared.appearance = NSAppearance(named: colorScheme.nsAppearanceName)
}
#endif
