#if os(macOS)
import AppKit
import RielaAppSupport

extension DaemonWorkflowWindowController {
  enum Column {
    static let instance = NSUserInterfaceItemIdentifier("instance")
  }

  enum InstanceState: String {
    case running = "Running"
    case starting = "Starting"
    case reloading = "Reloading"
    case stopping = "Stopping"
    case stopped = "Stopped"
    case failed = "Failed"
    case needsSource = "Needs Source"

    var sortOrder: Int {
      switch self {
      case .failed: 0
      case .needsSource: 1
      case .starting, .reloading, .stopping: 2
      case .running: 3
      case .stopped: 4
      }
    }

    var isTransitional: Bool {
      switch self {
      case .starting, .reloading, .stopping:
        true
      case .running, .stopped, .failed, .needsSource:
        false
      }
    }
  }

  enum DetailActionStyle {
    case normal
    case destructive

    var titleColor: NSColor {
      switch self {
      case .normal:
        .labelColor
      case .destructive:
        .systemRed
      }
    }
  }

  enum AddInstanceSheetAction {
    case importWorkflowOrPackageFromFile
    case importWorkflowOrPackageFromURL
  }

  enum ProfileDetailMode: Equatable {
    case overview
    case removalConfirmation
  }

  enum ImportSourceCopy {
    static let fileOrDirectoryTitle = "Import Package File or Directory"
    static let fileOrDirectoryDetail = "Add a workflow directory, package directory, .rielapkg, or .zip archive."
  }

  enum SourceActionContext {
    case addInstance
    case relink

    var importDetail: String {
      switch self {
      case .addInstance:
        "Import a workflow directory, package directory, or package file, then return to instance creation."
      case .relink:
        "Import a workflow directory, package directory, or package file, then return to relink this instance."
      }
    }
  }

  enum WorkflowSourceSelection {
    case selected(WorkflowSourceOption)
    case retry(String)
    case cancelled
  }

  enum InstanceDetailPane {
    case overview
    case inlineEnvironment
    case workflowVariables
    case eventSources
    case removalConfirmation
  }

  struct ConfiguredWorkflowInstanceRow {
    var id: String
    var profileName: RielaAppProfileName
    var localIdentity: String
    var preference: RielaAppDaemonWorkflowPreference
    var candidate: RielaAppDaemonWorkflowCandidate?
    var sourceIdentity: String
    var instanceName: String
    var workflowName: String
    var hasMissingRequiredEnvironment: Bool
    var state: InstanceState
    var stateDetail: String
  }

  struct WorkflowSourceOption {
    var sourceIdentity: String
    var candidate: RielaAppDaemonWorkflowCandidate
    var title: String
    var environmentStatus: String
    var location: String
  }
}
#endif
