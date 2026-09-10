#if os(macOS) && canImport(Network)
import AppKit
import Foundation
import RielaAppSupport
import RielaServer

extension RielaApp {
  func configureWebServer() {
    guard let assetRoot = RielaWebAssetLocator.locate() else {
      webServerSetupError = "Web assets are missing. Run bun run build in web/."
      return
    }
    let store = RielaAppWebServerSettingsStore(appRootURL: profileStore.appRootURL)
    webServerController = RielaAppWebServerController(
      app: self,
      settingsStore: store,
      assetRoot: assetRoot,
      onStateChange: { [weak self] in self?.rebuildMenu() }
    )
    webServerSetupError = store.load().diagnostic

  }

  @objc func startWebServerFromMenu() {
    Task { @MainActor [weak self] in
      await self?.webServerController?.start()
    }
  }

  @objc func stopWebServerFromMenu() {
    Task { @MainActor [weak self] in
      await self?.webServerController?.stop(explicit: true)
    }
  }

  @objc func openWebServerFromMenu() {
    webServerController?.openInBrowser()
  }

  @objc func openDesktopFromMenu() {
    openWebUI(context: "Riela")
  }

  /// The menu-bar host opens bundled assets over native IPC without starting HTTP.
  func openWebUI(context: String) {
    if desktopController == nil {
      desktopController = RielaDesktopController(app: self)
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await desktopController?.open()
        status = "Opened \(context) for profile \(daemonProfileName.rawValue)."
      } catch {
        status = "Failed to open \(context): \(error.localizedDescription)"
      }
      rebuildMenu()
    }
  }
}
#endif
