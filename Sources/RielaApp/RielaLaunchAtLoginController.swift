#if os(macOS)
import ServiceManagement

@MainActor
final class RielaLaunchAtLoginController {
  typealias StatusReader = @Sendable () -> SMAppService.Status

  private let readStatus: StatusReader
  private(set) var status: SMAppService.Status?
  private var refreshGeneration = 0

  init(readStatus: @escaping StatusReader = { SMAppService.mainApp.status }) {
    self.readStatus = readStatus
  }

  var isEnabled: Bool {
    status == .enabled
  }

  var statusDescription: String {
    guard let status else {
      return "Checking"
    }
    switch status {
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
    guard let status else {
      return nil
    }
    switch status {
    case .enabled, .notRegistered:
      return nil
    case .requiresApproval, .notFound:
      return statusDescription
    @unknown default:
      return statusDescription
    }
  }

  @discardableResult
  func refreshStatus() async -> Bool {
    refreshGeneration += 1
    let generation = refreshGeneration
    let reader = readStatus
    let refreshedStatus = await Task.detached(priority: .utility) {
      reader()
    }.value

    guard generation == refreshGeneration, refreshedStatus != status else {
      return false
    }
    status = refreshedStatus
    return true
  }

  func setEnabled(_ enabled: Bool) throws {
    let service = SMAppService.mainApp
    let current = service.status
    if enabled {
      guard current != .enabled, current != .requiresApproval else {
        return
      }
      try service.register()
    } else {
      guard current != .notRegistered, current != .notFound else {
        return
      }
      try service.unregister()
    }
  }
}
#endif
