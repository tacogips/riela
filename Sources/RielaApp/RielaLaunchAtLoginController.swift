#if os(macOS)
import ServiceManagement

@MainActor
struct RielaLaunchAtLoginController {
  var isEnabled: Bool {
    service.status == .enabled
  }

  var statusDescription: String {
    switch service.status {
    case .enabled:
      return "On"
    case .notRegistered:
      return "Off"
    case .requiresApproval:
      return "Requires approval in System Settings"
    case .notFound:
      return "Unavailable"
    @unknown default:
      return "Unknown"
    }
  }

  var menuSupplementaryStatusDescription: String? {
    switch service.status {
    case .enabled, .notRegistered:
      nil
    case .requiresApproval:
      "Requires approval in System Settings"
    case .notFound:
      "Unavailable"
    @unknown default:
      "Unknown"
    }
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try registerIfNeeded()
    } else {
      try unregisterIfNeeded()
    }
  }

  private var service: SMAppService {
    SMAppService.mainApp
  }

  private func registerIfNeeded() throws {
    guard service.status != .enabled, service.status != .requiresApproval else {
      return
    }
    try service.register()
  }

  private func unregisterIfNeeded() throws {
    guard service.status != .notRegistered, service.status != .notFound else {
      return
    }
    try service.unregister()
  }
}
#endif
