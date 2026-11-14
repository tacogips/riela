#if os(macOS)
import AppKit
import Foundation
import RielaAppSupport
import RielaNote
import RielaServer

extension RielaApp {
  func noteRootURL(profileName: RielaAppProfileName) -> URL {
    appHomeDirectory
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(profileName.rawValue, isDirectory: true)
      .appendingPathComponent("note", isDirectory: true)
  }

  /// Notes now live in the web UI: opening Notes ensures the local web server
  /// is running and opens the browser on it (the SwiftUI Notes window was
  /// removed after the web app reached feature parity).
  @objc func openNotes() {
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
        status = "Failed to open Notes: the web server did not start."
        rebuildMenu()
        return
      }
      webServerController.openInBrowser()
      status = "Opened Notes (web) for profile \(daemonProfileName.rawValue)."
      rebuildMenu()
    }
  }

  func noteAPIRegistrationBaseURL(profileName: RielaAppProfileName) -> String? {
    daemonRuntime.noteAPIEndpoint(noteRoot: noteRootURL(profileName: profileName).path)
  }
}
#endif
