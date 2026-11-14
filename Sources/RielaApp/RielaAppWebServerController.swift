#if os(macOS) && canImport(Network)
import AppKit
import Foundation
import RielaAppSupport
import RielaServer

extension RielaLocalHTTPServerState {
  var label: String {
    switch self {
    case .stopped: "stopped"
    case .starting: "starting"
    case .running: "running"
    case .stopping: "stopping"
    case .failed: "failed"
    }
  }
}

@MainActor
final class RielaAppWebServerController {
  private let settingsStore: RielaAppWebServerSettingsStore
  private let router: RielaAppWebRouter
  private let server: RielaLocalHTTPServer
  private let onStateChange: () -> Void

  private(set) var settings: RielaAppWebServerSettings
  private(set) var state: RielaLocalHTTPServerState = .stopped
  private(set) var restartRequired = false

  init(
    app: RielaApp,
    settingsStore: RielaAppWebServerSettingsStore,
    assetRoot: URL,
    onStateChange: @escaping () -> Void
  ) {
    self.settingsStore = settingsStore
    let loadResult = settingsStore.load()
    settings = loadResult.settings
    router = RielaAppWebRouter(app: app, assetRoot: assetRoot, configuredPort: loadResult.settings.port)
    server = RielaLocalHTTPServer(routeHandler: router)
    self.onStateChange = onStateChange
    server.setStateHandler { [weak self] nextState in
      Task { @MainActor [weak self] in
        guard let self else { return }
        state = nextState
        self.onStateChange()
      }
    }
  }

  var endpointURL: URL? {
    guard let port = state.boundPort else {
      return nil
    }
    return URL(string: "http://127.0.0.1:\(port)/")
  }

  var statusDescription: String {
    switch state {
    case .stopped:
      "Web Server: Stopped · configured 127.0.0.1:\(settings.port)"
    case let .starting(port):
      "Web Server: Starting 127.0.0.1:\(port)…"
    case let .running(port):
      restartRequired
        ? "Web Server: Running 127.0.0.1:\(port) · restart for :\(settings.port)"
        : "Web Server: Running 127.0.0.1:\(port)"
    case let .stopping(port):
      "Web Server: Stopping\(port.map { " 127.0.0.1:\($0)" } ?? "")…"
    case let .failed(message):
      "Web Server: Failed · \(message)"
    }
  }

  func start() async {
    switch state {
    case .starting, .running, .stopping:
      return
    case .stopped, .failed:
      break
    }
    router.updateConfiguredPort(settings.port)
    do {
      let boundPort = try await server.start(port: settings.port)
      state = .running(port: boundPort)
      settings.isEnabled = true
      restartRequired = false
      try settingsStore.save(settings)
    } catch {
      state = .failed(message: sanitized(error.localizedDescription))
    }
    onStateChange()
  }

  func stop(explicit: Bool) async {
    await server.stop()
    state = .stopped
    restartRequired = false
    if explicit {
      settings.isEnabled = false
      do {
        try settingsStore.save(settings)
      } catch {
        state = .failed(message: sanitized(error.localizedDescription))
      }
    }
    onStateChange()
  }

  func shutdownForTermination() async {
    await stop(explicit: false)
  }

  func updateConfiguredPort(_ port: Int) throws {
    var candidate = settings
    candidate.port = port
    try settingsStore.save(candidate)
    settings = candidate
    if state.boundPort != nil {
      restartRequired = state.boundPort != port
    } else {
      router.updateConfiguredPort(port)
      restartRequired = false
    }
    onStateChange()
  }

  func openInBrowser() {
    guard let endpointURL else { return }
    NSWorkspace.shared.open(endpointURL)
  }

  private func sanitized(_ message: String) -> String {
    let singleLine = message.replacingOccurrences(of: "\n", with: " ")
    return singleLine.count <= 180 ? singleLine : String(singleLine.prefix(180))
  }
}
#endif
