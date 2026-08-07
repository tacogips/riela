#if canImport(AppKit)
import AppKit
import Foundation
import RielaCore
import RielaServer

// Appearance settings web API. Formerly co-located with the removed note
// settings API (the note subsystem now lives in the kaiba package).
extension RielaApp {
  func webAppearanceSettingsJSON() -> JSONObject {
    [
      "profile": .string(daemonProfileName.rawValue),
      "revision": .number(Double(webRevision)),
      "colorScheme": .string(appearanceSettingsStore.load().colorScheme.rawValue),
      "options": .array(RielaAppColorScheme.allCases.map { .string($0.rawValue) })
    ]
  }

  func webUpdateAppearanceSettings(colorScheme rawValue: String) -> RielaHTTPResponse {
    guard let colorScheme = RielaAppColorScheme(rawValue: rawValue) else {
      return webAppearanceError(
        status: 400,
        code: "invalid_settings",
        message: "colorScheme must be one of \(RielaAppColorScheme.allCases.map(\.rawValue).joined(separator: ", "))."
      )
    }
    do {
      try appearanceSettingsStore.save(RielaAppAppearanceSettings(colorScheme: colorScheme))
    } catch {
      return webAppearanceError(
        status: 500,
        code: "persistence_failed",
        message: error.localizedDescription
      )
    }
    rielaAppApplyColorScheme(colorScheme)
    webRevision += 1
    return .json(status: 200, .object(webAppearanceSettingsJSON()))
  }

  private func webAppearanceError(status: Int, code: String, message: String) -> RielaHTTPResponse {
    .json(status: status, .object([
      "error": .object([
        "code": .string(code),
        "message": .string(message)
      ])
    ]))
  }
}
#endif
