#if os(macOS)
import Foundation

public struct RielaAppProfileInstanceIdentity: Equatable, Hashable, Sendable, CustomStringConvertible {
  public var profileName: RielaAppProfileName
  public var identity: String

  public init(profileName: RielaAppProfileName, identity: String) {
    self.profileName = profileName
    self.identity = identity
  }

  public init?(rawValue: String) {
    guard let separator = rawValue.firstIndex(of: ":"),
          let profileLength = Int(rawValue[..<separator]),
          profileLength >= 0 else {
      return nil
    }
    let profileStart = rawValue.index(after: separator)
    guard let profileEnd = rawValue.index(profileStart, offsetBy: profileLength, limitedBy: rawValue.endIndex) else {
      return nil
    }
    let profileRawValue = String(rawValue[profileStart..<profileEnd])
    let identity = String(rawValue[profileEnd...])
    guard !profileRawValue.isEmpty, !identity.isEmpty else {
      return nil
    }
    self.profileName = RielaAppProfileName(profileRawValue)
    self.identity = identity
  }

  public var rawValue: String {
    "\(profileName.rawValue.count):\(profileName.rawValue)\(identity)"
  }

  public var description: String {
    rawValue
  }
}

public struct RielaAppProfiledWorkflowInstance: Identifiable, Equatable, Sendable {
  public var profileName: RielaAppProfileName
  public var instance: WorkflowInstance

  public init(profileName: RielaAppProfileName, instance: WorkflowInstance) {
    self.profileName = profileName
    self.instance = instance
  }

  public var id: String {
    runtimeIdentity.rawValue
  }

  public var runtimeIdentity: RielaAppProfileInstanceIdentity {
    RielaAppProfileInstanceIdentity(profileName: profileName, identity: instance.identity)
  }

  public var runtimeCandidate: RielaAppDaemonWorkflowCandidate {
    instance.source.managedInstance(
      identity: runtimeIdentity.rawValue,
      displayName: instance.preference.displayName
    )
  }

  public var localIdentity: String {
    instance.identity
  }

  public var preference: RielaAppDaemonWorkflowPreference {
    instance.preference
  }
}
#endif
