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

  /// Starts the local web server when needed and opens it in the browser.
  /// Every "open" action funnels through here because the AppKit workflow
  /// viewer window was removed once the web app took over run inspection.
  /// - Parameter context: Noun phrase naming the surface, used in status text.
  func openWebUI(context: String) {
    Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      guard let webServerController else {
        status = webServerSetupError ?? "Web Server: Unavailable"
        rebuildMenu()
        return
      }
      if webServerController.endpointURL == nil {
        await webServerController.start()
      }
      guard webServerController.endpointURL != nil else {
        status = "Failed to open \(context): the web server did not start."
        rebuildMenu()
        return
      }
      webServerController.openInBrowser()
      status = "Opened \(context) (web) for profile \(daemonProfileName.rawValue)."
      rebuildMenu()
    }
  }
}
#endif
