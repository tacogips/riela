#if os(macOS)
import AppKit
import Foundation
import RielaAppSupport

extension RielaApp {
  func noteRootURL(profileName: RielaAppProfileName) -> URL {
    appHomeDirectory
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(profileName.rawValue, isDirectory: true)
      .appendingPathComponent("note", isDirectory: true)
  }

  @objc func openNotes() {
    do {
      if noteWindowController == nil {
        noteWindowController = try NoteWindowController(
          noteRoot: noteRootURL(profileName: daemonProfileName),
          profileName: daemonProfileName,
          onOpenSettings: { [weak self] in
            self?.openNoteSettings()
          },
          onWindowWillClose: { [weak self] in
            self?.noteWindowController = nil
            self?.restoreAccessoryActivationPolicyIfNoAppWindows()
          }
        )
      }
      promoteToRegularApplication()
      noteWindowController?.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)
      status = "Opened Notes for profile \(daemonProfileName.rawValue)."
      rebuildMenu()
    } catch {
      status = "Failed to open Notes: \(error.localizedDescription)"
      rebuildMenu()
    }
  }

  @objc func openNoteSettings() {
    do {
      if noteSettingsWindowController == nil {
        let profileName = daemonProfileName
        noteSettingsWindowController = try NoteSettingsWindowController(
          noteRoot: noteRootURL(profileName: profileName),
          profileName: profileName,
          registrationBaseURLProvider: { [weak self] in
            self?.noteAPIRegistrationBaseURL(profileName: profileName)
          },
          onWindowWillClose: { [weak self] in
            self?.noteSettingsWindowController = nil
            self?.restoreAccessoryActivationPolicyIfNoAppWindows()
          }
        )
      }
      promoteToRegularApplication()
      noteSettingsWindowController?.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)
      status = "Opened Notes settings for profile \(daemonProfileName.rawValue)."
      rebuildMenu()
    } catch {
      status = "Failed to open Notes settings: \(error.localizedDescription)"
      rebuildMenu()
    }
  }

  func noteAPIRegistrationBaseURL(profileName: RielaAppProfileName) -> String? {
    daemonRuntime.noteAPIEndpoint(noteRoot: noteRootURL(profileName: profileName).path)
  }
}
#endif
