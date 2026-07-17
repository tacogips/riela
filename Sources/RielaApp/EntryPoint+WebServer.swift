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
    guard webServerController?.settings.isEnabled == true else {
      return
    }
    Task { @MainActor [weak self] in
      await self?.webServerController?.start()
    }
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
}
#endif
