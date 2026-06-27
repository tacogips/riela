#if os(macOS)
public struct RielaAppImportSummary: Equatable, Sendable {
  public var importedNames: [String]
  public var updatedNames: [String]
  public var failures: [String]
  public var profileName: RielaAppProfileName
  public var startsImmediately: Bool
  public var autostartOffNames: [String]

  public init(
    importedNames: [String],
    updatedNames: [String] = [],
    failures: [String],
    profileName: RielaAppProfileName,
    startsImmediately: Bool,
    autostartOffNames: [String] = []
  ) {
    self.importedNames = importedNames
    self.updatedNames = updatedNames
    self.failures = failures
    self.profileName = profileName
    self.startsImmediately = startsImmediately
    self.autostartOffNames = autostartOffNames
  }

  public var statusMessage: String? {
    guard hasSuccessfulImports || !failures.isEmpty else {
      return nil
    }
    if failures.isEmpty {
      return importedStatus
    }
    if !hasSuccessfulImports {
      return "Import failed: \(failures.joined(separator: "; "))"
    }
    return "Import completed with errors; \(successfulSegments.joined(separator: "; ")); failed: \(failures.joined(separator: "; "))"
  }

  private var hasSuccessfulImports: Bool {
    !importedNames.isEmpty || !updatedNames.isEmpty
  }

  private var importedStatus: String {
    if updatedNames.isEmpty, importedNames.count == 1, let name = importedNames.first {
      return singleStatus(action: "Imported", name: name)
    }
    if importedNames.isEmpty, updatedNames.count == 1, let name = updatedNames.first {
      return singleStatus(action: "Updated", name: name)
    }
    let profileStatus = "\(successfulSummary) in profile \(profileName.rawValue)"
    return autoStartOffSuffix.isEmpty ? profileStatus : "\(profileStatus)\(autoStartOffSuffix)"
  }

  private func singleStatus(action: String, name: String) -> String {
    let preposition = action == "Imported" ? "into" : "in"
    let profileStatus = "\(action) \(name) \(preposition) profile \(profileName.rawValue)"
    return autostartOffNames.contains(name) || !startsImmediately
      ? "\(profileStatus) with auto-start off"
      : profileStatus
  }

  private var autoStartOffSuffix: String {
    if !autostartOffNames.isEmpty {
      return "; auto-start off: \(autostartOffNames.joined(separator: ", "))"
    }
    return startsImmediately ? "" : " with auto-start off"
  }

  private var successfulSummary: String {
    let importedCount = importCountDescription(importedNames.count)
    let updatedCount = updateCountDescription(updatedNames.count)
    switch (importedNames.isEmpty, updatedNames.isEmpty) {
    case (false, true):
      return "Imported \(importedCount)"
    case (true, false):
      return "Updated \(updatedCount)"
    case (false, false):
      return "Imported \(importedCount) and updated \(updatedCount)"
    case (true, true):
      return "Imported 0 items"
    }
  }

  private var successfulSegments: [String] {
    var segments: [String] = []
    if !importedNames.isEmpty {
      segments.append("imported: \(importedNames.joined(separator: ", "))")
    }
    if !updatedNames.isEmpty {
      segments.append("updated: \(updatedNames.joined(separator: ", "))")
    }
    if !autostartOffNames.isEmpty {
      segments.append("auto-start off: \(autostartOffNames.joined(separator: ", "))")
    }
    return segments
  }
}

public struct RielaAppProjectImportSummary: Equatable, Sendable {
  public struct Project: Equatable, Sendable {
    public var name: String
    public var workflowCount: Int
    public var alreadyAdded: Bool

    public init(name: String, workflowCount: Int, alreadyAdded: Bool) {
      self.name = name
      self.workflowCount = workflowCount
      self.alreadyAdded = alreadyAdded
    }
  }

  public var projects: [Project]
  public var failures: [String]
  public var profileName: RielaAppProfileName

  public init(projects: [Project], failures: [String], profileName: RielaAppProfileName) {
    self.projects = projects
    self.failures = failures
    self.profileName = profileName
  }

  public var statusMessage: String? {
    guard !projects.isEmpty || !failures.isEmpty else {
      return nil
    }
    if projects.count == 1, failures.isEmpty, let project = projects.first {
      return project.alreadyAdded
        ? "Project already in profile \(profileName.rawValue): \(project.name) (\(workflowCountDescription(project.workflowCount)))"
        : "Added project to profile \(profileName.rawValue): \(project.name) (\(workflowCountDescription(project.workflowCount)))"
    }
    if projects.isEmpty {
      return "Project import failed: \(failures.joined(separator: "; "))"
    }
    let totalWorkflows = projects.reduce(0) { $0 + $1.workflowCount }
    let alreadyAddedCount = projects.filter(\.alreadyAdded).count
    let addedCount = projects.count - alreadyAddedCount
    var status = addedCount > 0
      ? "Added \(countDescription(addedCount, singular: "project", plural: "projects")) to profile \(profileName.rawValue)"
      : "Projects already in profile \(profileName.rawValue)"
    if alreadyAddedCount > 0, addedCount > 0 {
      status += "; \(alreadyAddedCount) already in profile"
    }
    status += " (\(workflowCountDescription(totalWorkflows)))"
    if !failures.isEmpty {
      status += "; failed: \(failures.joined(separator: "; "))"
    }
    return status
  }
}

public struct RielaAppProfileSwitchSummary: Equatable, Sendable {
  public var rawProfileName: String
  public var profileName: RielaAppProfileName
  public var autostartsDaemonWorkflows: Bool

  public init(
    rawProfileName: String,
    profileName: RielaAppProfileName,
    autostartsDaemonWorkflows: Bool
  ) {
    self.rawProfileName = rawProfileName
    self.profileName = profileName
    self.autostartsDaemonWorkflows = autostartsDaemonWorkflows
  }

  public var statusMessage: String {
    let baseStatus: String
    let typedName = rawProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    if typedName.isEmpty || typedName == profileName.rawValue {
      baseStatus = "Profile: \(profileName.rawValue)"
    } else {
      baseStatus = "Profile: \(profileName.rawValue) (safe name for \(typedName))"
    }
    return autostartsDaemonWorkflows ? baseStatus : "\(baseStatus); auto-start off"
  }
}

public func workflowCountDescription(_ count: Int) -> String {
  switch count {
  case 0:
    return "no workflows"
  case 1:
    return "1 workflow"
  default:
    return "\(count) workflows"
  }
}

private func countDescription(_ count: Int, singular: String, plural: String) -> String {
  count == 1 ? "1 \(singular)" : "\(count) \(plural)"
}

private func importCountDescription(_ count: Int) -> String {
  countDescription(count, singular: "item", plural: "items")
}

private func updateCountDescription(_ count: Int) -> String {
  countDescription(count, singular: "item", plural: "items")
}
#endif
