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
    openWebUI(context: "Notes")
  }

  func noteAPIRegistrationBaseURL(profileName: RielaAppProfileName) -> String? {
    daemonRuntime.noteAPIEndpoint(noteRoot: noteRootURL(profileName: profileName).path)
  }
}
#endif
