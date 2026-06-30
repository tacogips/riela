#if os(macOS)
import AppKit
import Foundation
import RielaAddons
import RielaAppSupport
import RielaCore

extension RielaApp {
  func addDaemonWorkflowInstance(_ request: DaemonWorkflowAddInstanceRequest) {
    guard let source = daemonWorkflowSources.first(where: { $0.id == request.sourceIdentity }) else {
      status = "Workflow source could not be found"
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
      status = "Instance needs a workflow source"
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
      status = "Instance needs a workflow source"
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
      status = "Instance needs a workflow source"
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
      status = "Instance could not be found"
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

  func relinkDaemonWorkflowInstance(identity: String, sourceIdentity: String) {
    guard let source = daemonWorkflowSources.first(where: { candidate in
      candidate.id == sourceIdentity || candidate.sourceIdentity == sourceIdentity
    }) else {
      status = "Workflow source could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    guard updateDaemonPreference(identity: identity, mutate: { preference in
      preference.identity = identity
      preference.sourceIdentity = source.id
      preference.available = true
      preference.active = false
    }) else {
      return
    }
    Task { @MainActor in
      await daemonRuntime.stop(identity: identity)
      status = "Relinked \(identity) to \(source.displayName)"
      refreshDaemonWorkflowWindow()
      daemonWindowController?.selectCandidate(identity: identity)
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
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let defaultId = uniqueDaemonInstanceId(for: candidate)
    guard let result = promptForDaemonInstance(
      title: "New Instance",
      message: "Create another saved instance from \(candidate.displayName).",
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
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    guard let result = promptForDaemonInstance(
      title: "Instance Name",
      message: "Update the saved instance identifier and display name for \(candidate.displayName).",
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
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let existing = environmentText(from: daemonState.preference(for: identity).environmentVariables)
    guard let text = promptForMultilineValue(
      title: "Environment Variables",
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
      status = "Updated environment variables for \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
      restartActiveDaemonWorkflowAfterConfigurationChange(
        identity: identity,
        changeDescription: "environment variables"
      )
    } catch {
      status = "Invalid environment variables: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
    }
  }

  func setDaemonWorkflowDefaultVariables(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Instance could not be found"
      refreshDaemonWorkflowWindow()
      return
    }
    let existing = workflowVariablesText(from: daemonState.preference(for: identity).defaultVariables)
    guard let text = promptForMultilineValue(
      title: "Workflow Variables",
      message: "Enter workflow variables for \(candidate.displayName). Use key=value or key:=JSON lines.",
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
      status = "Updated workflow variables for \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
      restartActiveDaemonWorkflowAfterConfigurationChange(
        identity: identity,
        changeDescription: "workflow variables"
      )
    } catch {
      status = "Invalid workflow variables: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
    }
  }

  private struct InstancePromptResult {
    var identity: String
    var displayName: String?
  }

  private var daemonInstancePromptViewFactory: DaemonInstancePromptViewFactory {
    DaemonInstancePromptViewFactory()
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
    let stack = daemonInstancePromptViewFactory.nameEditorStack(idField: idField, nameField: nameField)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.accessoryView = stack
    alert.addButton(withTitle: "Done")
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

  private func promptForMultilineValue(title: String, message: String, value: String) -> String? {
    RielaAppSettingsEditorWindowController.editMultiline(title: title, message: message, value: value)
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

@MainActor
struct DaemonInstancePromptViewFactory {
  static let nameEditorSize = NSSize(width: 360, height: 104)
  static let variableEditorSize = NSSize(width: 440, height: 225)
  static let editorTextSize = NSSize(width: 380, height: 160)

  func nameEditorStack(idField: NSTextField, nameField: NSTextField) -> NSStackView {
    accessoryStack(
      views: [
        sectionTitle("Instance Settings"),
        fieldRow(title: "Instance ID", control: idField),
        fieldRow(title: "Display Name", control: nameField)
      ],
      size: Self.nameEditorSize
    )
  }

  func variableEditorStack(currentValue: String, editorView: NSView) -> NSStackView {
    let lineCount = currentValue
      .split(whereSeparator: \.isNewline)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .count
    let lineCountLabel = NSTextField(labelWithString: "\(lineCount) configured")
    lineCountLabel.lineBreakMode = .byTruncatingTail
    lineCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    editorView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    let preferredHeight = editorView.heightAnchor.constraint(equalToConstant: Self.editorTextSize.height)
    preferredHeight.priority = .defaultLow
    preferredHeight.isActive = true
    return accessoryStack(
      views: [
        sectionTitle("Variable Settings"),
        fieldRow(title: "Current Lines", control: lineCountLabel),
        fieldRow(title: "Editor", control: editorView)
      ],
      size: Self.variableEditorSize
    )
  }

  private func accessoryStack(views: [NSView], size: NSSize) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.spacing = 8
    stack.alignment = .width
    stack.frame = NSRect(origin: .zero, size: size)
    stack.widthAnchor.constraint(lessThanOrEqualToConstant: size.width).isActive = true
    return stack
  }

  private func sectionTitle(_ text: String) -> NSTextField {
    let title = NSTextField(labelWithString: text)
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return title
  }

  private func fieldRow(title: String, control: NSView) -> NSStackView {
    let titleLabel = rielaAppSettingsTitleLabel(title, maxWidth: 130)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [titleLabel, control])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    return rielaAppSettingsRow(row)
  }
}
#endif
