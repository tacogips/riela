#if os(macOS)
import AppKit
import Foundation
import RielaAddons
import RielaAppSupport
import RielaCore

extension RielaApp {
  func addDaemonWorkflowInstance(_ request: DaemonWorkflowAddInstanceRequest) {
    guard let source = daemonWorkflowSources.first(where: { $0.id == request.sourceIdentity }) else {
      status = "Selected workflow source is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    let defaultIdentity = uniqueDaemonInstanceId(for: source)
    let identity = sanitizedDaemonInstanceId(request.identity).isEmpty
      ? defaultIdentity
      : sanitizedDaemonInstanceId(request.identity)
    guard !daemonState.preferences.keys.contains(identity) else {
      status = "Instance ID already exists: \(identity)"
      refreshDaemonWorkflowWindow()
      return
    }
    let previousPreference = daemonState.preferences[identity]
    let preference = RielaAppDaemonWorkflowPreference(
      identity: identity,
      sourceIdentity: source.id,
      displayName: request.displayName,
      available: true,
      active: request.startsImmediately,
      workingDirectory: request.workingDirectory,
      environmentFilePath: request.environmentFilePath
    )
    daemonState.preferences[identity] = preference
    guard saveDaemonState() else {
      if let previousPreference {
        daemonState.preferences[identity] = previousPreference
      } else {
        daemonState.preferences.removeValue(forKey: identity)
      }
      refreshDaemonWorkflowWindow()
      return
    }
    status = "Created instance \(identity)"
    refreshDaemonWorkflowWindow()
    daemonWindowController?.selectCandidate(identity: identity)
    guard request.startsImmediately,
      let candidate = daemonCandidateForInstance(identity: identity)
    else {
      return
    }
    Task { @MainActor in
      await daemonRuntime.start(
        candidate,
        configuration: daemonRuntimeConfiguration(for: candidate)
      )
      status = "Started \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
      daemonWindowController?.selectCandidate(identity: identity)
    }
  }

  func startDaemonWorkflowInstance(identity: String) {
    guard let candidate = daemonCandidateForInstance(identity: identity) else {
      status = "Selected instance needs a workflow source"
      refreshDaemonWorkflowWindow()
      return
    }
    guard updateDaemonPreference(identity: identity, mutate: { preference in
      preference.sourceIdentity = candidate.sourceIdentity
      preference.available = true
      preference.active = true
    }) else {
      return
    }
    Task { @MainActor in
      await daemonRuntime.start(
        candidate,
        configuration: daemonRuntimeConfiguration(for: candidate)
      )
      status = "Started \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
    }
  }

  func stopDaemonWorkflowInstance(identity: String) {
    guard let candidate = daemonCandidateForInstance(identity: identity) else {
      status = "Selected instance needs a workflow source"
      refreshDaemonWorkflowWindow()
      return
    }
    guard updateDaemonPreference(identity: identity, mutate: { preference in
      preference.sourceIdentity = candidate.sourceIdentity
      preference.available = true
      preference.active = false
    }) else {
      return
    }
    Task { @MainActor in
      await daemonRuntime.stop(identity: identity)
      status = "Stopped \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
    }
  }

  func restartDaemonWorkflowInstance(identity: String) {
    guard let candidate = daemonCandidateForInstance(identity: identity) else {
      status = "Selected instance needs a workflow source"
      refreshDaemonWorkflowWindow()
      return
    }
    guard updateDaemonPreference(identity: identity, mutate: { preference in
      preference.sourceIdentity = candidate.sourceIdentity
      preference.available = true
      preference.active = true
    }) else {
      return
    }
    Task { @MainActor in
      await daemonRuntime.stop(identity: identity)
      await daemonRuntime.start(
        candidate,
        configuration: daemonRuntimeConfiguration(for: candidate)
      )
      status = "Restarted \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
    }
  }

  func removeDaemonWorkflowInstance(identity: String) {
    let previousPreference = daemonState.preferences[identity]
    guard previousPreference != nil else {
      status = "Selected instance is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    daemonState.preferences.removeValue(forKey: identity)
    guard saveDaemonState() else {
      if let previousPreference {
        daemonState.preferences[identity] = previousPreference
      }
      refreshDaemonWorkflowWindow()
      return
    }
    Task { @MainActor in
      await daemonRuntime.stop(identity: identity)
      status = "Removed instance \(identity)"
      refreshDaemonWorkflowWindow()
    }
  }

  func daemonCandidateForInstance(identity: String) -> RielaAppDaemonWorkflowCandidate? {
    if let candidate = daemonCandidates.first(where: { $0.id == identity }) {
      return candidate
    }
    let preference = daemonState.preference(for: identity)
    let sourceIdentity = preference.sourceIdentity ?? identity
    guard let source = daemonWorkflowSources.first(where: { $0.id == sourceIdentity }) else {
      return nil
    }
    return source.managedInstance(identity: identity, displayName: preference.displayName)
  }

  func duplicateDaemonWorkflowInstance(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected instance is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    let defaultId = uniqueDaemonInstanceId(for: candidate)
    guard let result = promptForDaemonInstance(
      title: "Duplicate Workflow Instance",
      message: "Create another managed instance from \(candidate.displayName).",
      idValue: defaultId,
      displayNameValue: "\(candidate.displayName) copy"
    ) else {
      return
    }
    guard !daemonState.preferences.keys.contains(result.identity) else {
      status = "Instance ID already exists: \(result.identity)"
      refreshDaemonWorkflowWindow()
      return
    }
    let selectedPreference = daemonState.preference(for: candidate.id)
    let preference = RielaAppDaemonWorkflowPreference(
      identity: result.identity,
      sourceIdentity: candidate.sourceIdentity,
      displayName: result.displayName,
      available: true,
      active: false,
      environmentFilePath: selectedPreference.environmentFilePath,
      environmentVariables: selectedPreference.environmentVariables,
      defaultVariables: selectedPreference.defaultVariables,
      nodePatches: selectedPreference.nodePatches
    )
    daemonState.preferences[result.identity] = preference
    guard saveDaemonState() else {
      daemonState.preferences.removeValue(forKey: result.identity)
      refreshDaemonWorkflowWindow()
      return
    }
    status = "Created instance \(result.identity)"
    refreshDaemonWorkflowWindow()
    daemonWindowController?.selectCandidate(identity: result.identity)
  }

  func renameDaemonWorkflowInstance(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected instance is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    guard let result = promptForDaemonInstance(
      title: "Rename Workflow Instance",
      message: "Change the management id and display name for \(candidate.displayName).",
      idValue: identity,
      displayNameValue: candidate.displayName
    ) else {
      return
    }
    let previousPreference = daemonState.preferences[identity]
    let previousTargetPreference = daemonState.preferences[result.identity]
    if result.identity != identity, previousTargetPreference != nil {
      status = "Instance ID already exists: \(result.identity)"
      refreshDaemonWorkflowWindow()
      return
    }
    var preference = daemonState.preference(for: identity)
    preference.identity = result.identity
    preference.sourceIdentity = candidate.sourceIdentity
    preference.displayName = result.displayName
    let shouldRestart = preference.available && preference.active
    daemonState.preferences.removeValue(forKey: identity)
    daemonState.preferences[result.identity] = preference
    guard saveDaemonState() else {
      daemonState.preferences.removeValue(forKey: result.identity)
      if let previousPreference {
        daemonState.preferences[identity] = previousPreference
      }
      if let previousTargetPreference {
        daemonState.preferences[result.identity] = previousTargetPreference
      }
      refreshDaemonWorkflowWindow()
      return
    }
    Task { @MainActor in
      if result.identity != identity {
        await daemonRuntime.stop(identity: identity)
      }
      status = "Renamed instance to \(result.identity)"
      refreshDaemonWorkflowWindow()
      if shouldRestart, let renamedCandidate = daemonCandidates.first(where: { $0.id == result.identity }) {
        await daemonRuntime.start(
          renamedCandidate,
          configuration: daemonRuntimeConfiguration(for: renamedCandidate)
        )
        refreshDaemonWorkflowWindow()
      }
      daemonWindowController?.selectCandidate(identity: result.identity)
    }
  }

  func setDaemonWorkflowEnvironmentVariables(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected instance is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    let existing = environmentText(from: daemonState.preference(for: identity).environmentVariables)
    guard let text = promptForMultilineValue(
      title: "Instance Environment Variables",
      message: "Enter KEY=VALUE lines for instance \(candidate.displayName).",
      value: existing
    ) else {
      return
    }
    do {
      let variables = try parseEnvironmentVariables(text)
      guard updateDaemonPreference(identity: identity, mutate: { preference in
        preference.sourceIdentity = candidate.sourceIdentity
        preference.environmentVariables = variables
      }) else {
        return
      }
      status = "Updated inline env for \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
      restartActiveDaemonWorkflowAfterConfigurationChange(
        identity: identity,
        changeDescription: "inline env"
      )
    } catch {
      status = "Invalid env vars: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
    }
  }

  func setDaemonWorkflowDefaultVariables(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected instance is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    let existing = workflowVariablesText(from: daemonState.preference(for: identity).defaultVariables)
    guard let text = promptForMultilineValue(
      title: "Instance Variables",
      message: "Enter key=value lines for instance \(candidate.displayName). Use key:=JSON for typed values.",
      value: existing
    ) else {
      return
    }
    do {
      let variables = try parseWorkflowVariables(text)
      guard updateDaemonPreference(identity: identity, mutate: { preference in
        preference.sourceIdentity = candidate.sourceIdentity
        preference.defaultVariables = variables
      }) else {
        return
      }
      status = "Updated instance variables for \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
      restartActiveDaemonWorkflowAfterConfigurationChange(
        identity: identity,
        changeDescription: "instance variables"
      )
    } catch {
      status = "Invalid instance variables: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
    }
  }

  private struct InstancePromptResult {
    var identity: String
    var displayName: String?
  }

  private func promptForDaemonInstance(
    title: String,
    message: String,
    idValue: String,
    displayNameValue: String
  ) -> InstancePromptResult? {
    let idField = NSTextField(string: idValue)
    idField.placeholderString = "instance-id"
    let nameField = NSTextField(string: displayNameValue)
    nameField.placeholderString = "Display name"
    let fieldsTitle = NSTextField(labelWithString: "Instance Settings")
    fieldsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let stack = NSStackView(views: [
      fieldsTitle,
      daemonInstancePromptFieldRow(title: "Instance ID", control: idField),
      daemonInstancePromptFieldRow(title: "Display Name", control: nameField)
    ])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 420, height: 110)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.accessoryView = stack
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }
    let identity = sanitizedDaemonInstanceId(idField.stringValue)
    guard !identity.isEmpty else {
      status = "Instance ID is required"
      refreshDaemonWorkflowWindow()
      return nil
    }
    let displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return InstancePromptResult(identity: identity, displayName: displayName.isEmpty ? nil : displayName)
  }

  private func daemonInstancePromptFieldRow(title: String, control: NSView) -> NSStackView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
    control.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
    let row = NSStackView(views: [titleLabel, control])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    row.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
    return row
  }

  private func promptForMultilineValue(title: String, message: String, value: String) -> String? {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.string = value
    let scrollView = NSScrollView(frame: textView.frame)
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.accessoryView = scrollView
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }
    return textView.string
  }

  private func uniqueDaemonInstanceId(for candidate: RielaAppDaemonWorkflowCandidate) -> String {
    let base = sanitizedDaemonInstanceId("\(candidate.sourceIdentity)-instance")
    var candidateId = base
    var suffix = 2
    while daemonState.preferences[candidateId] != nil {
      candidateId = "\(base)-\(suffix)"
      suffix += 1
    }
    return candidateId
  }

  private func sanitizedDaemonInstanceId(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    let mapped = trimmed.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_ :"))
  }

  private func environmentText(from variables: [String: String]) -> String {
    variables.keys.sorted().map { key in
      "\(key)=\(variables[key] ?? "")"
    }.joined(separator: "\n")
  }

  private func parseEnvironmentVariables(_ text: String) throws -> [String: String] {
    var variables: [String: String] = [:]
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else {
        continue
      }
      guard let separator = line.firstIndex(of: "=") else {
        throw NSError(domain: "RielaApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing '=' in \(line)"])
      }
      let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      guard WorkflowPackageManifestValidator.isValidEnvironmentVariableName(name) else {
        throw NSError(domain: "RielaApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid name \(name)"])
      }
      variables[name] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }
    return variables
  }

  private func workflowVariablesText(from variables: JSONObject) -> String {
    variables.keys.sorted().map { key in
      guard let value = variables[key] else {
        return "\(key)="
      }
      if case let .string(stringValue) = value {
        return "\(key)=\(stringValue)"
      }
      return "\(key):=\(jsonText(from: value))"
    }.joined(separator: "\n")
  }

  private func parseWorkflowVariables(_ text: String) throws -> JSONObject {
    var variables: JSONObject = [:]
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else {
        continue
      }
      if let typedSeparator = line.range(of: ":=") {
        let name = String(line[..<typedSeparator.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
          throw NSError(domain: "RielaApp", code: 3, userInfo: [NSLocalizedDescriptionKey: "variable name is required"])
        }
        let valueText = String(line[typedSeparator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !valueText.isEmpty else {
          throw NSError(domain: "RielaApp", code: 4, userInfo: [NSLocalizedDescriptionKey: "typed value is required for \(name)"])
        }
        variables[name] = try JSONDecoder().decode(JSONValue.self, from: Data(valueText.utf8))
        continue
      }
      guard let separator = line.firstIndex(of: "=") else {
        throw NSError(domain: "RielaApp", code: 5, userInfo: [NSLocalizedDescriptionKey: "missing '=' in \(line)"])
      }
      let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else {
        throw NSError(domain: "RielaApp", code: 6, userInfo: [NSLocalizedDescriptionKey: "variable name is required"])
      }
      variables[name] = .string(String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
    }
    return variables
  }

  private func jsonText(from value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let text = String(data: data, encoding: .utf8) else {
      return "null"
    }
    return text
  }
}
#endif
