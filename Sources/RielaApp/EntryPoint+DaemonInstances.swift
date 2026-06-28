#if os(macOS)
import AppKit
import Foundation
import RielaAddons
import RielaAppSupport
import RielaCore

extension RielaApp {
  func duplicateDaemonWorkflowInstance(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected workflow is no longer available"
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
      status = "Management ID already exists: \(result.identity)"
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
    status = "Created workflow instance \(result.identity)"
    refreshDaemonWorkflowWindow()
    daemonWindowController?.selectCandidate(identity: result.identity)
  }

  func renameDaemonWorkflowInstance(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected workflow is no longer available"
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
      status = "Management ID already exists: \(result.identity)"
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
      status = "Renamed workflow instance to \(result.identity)"
      refreshDaemonWorkflowWindow()
      if shouldRestart, let renamedCandidate = daemonCandidates.first(where: { $0.id == result.identity }) {
        let preference = daemonState.preference(for: renamedCandidate.id)
        await daemonRuntime.start(
          renamedCandidate,
          inheritedEnvironment: daemonEnvironment(for: renamedCandidate),
          defaultVariables: preference.defaultVariables,
          nodePatch: preference.nodePatchJSONObject
        )
        refreshDaemonWorkflowWindow()
      }
      daemonWindowController?.selectCandidate(identity: result.identity)
    }
  }

  func setDaemonWorkflowEnvironmentVariables(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected workflow is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    let existing = environmentText(from: daemonState.preference(for: identity).environmentVariables)
    guard let text = promptForMultilineValue(
      title: "Environment Variables",
      message: "Enter KEY=VALUE lines for \(candidate.displayName).",
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
    } catch {
      status = "Invalid env vars: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
    }
  }

  func setDaemonWorkflowDefaultVariables(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected workflow is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    let existing = jsonText(from: daemonState.preference(for: identity).defaultVariables)
    guard let text = promptForMultilineValue(
      title: "Workflow Variables",
      message: "Enter a JSON object for \(candidate.displayName).",
      value: existing
    ) else {
      return
    }
    do {
      let variables = try parseJSONObject(text)
      guard updateDaemonPreference(identity: identity, mutate: { preference in
        preference.sourceIdentity = candidate.sourceIdentity
        preference.defaultVariables = variables
      }) else {
        return
      }
      status = "Updated workflow variables for \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
    } catch {
      status = "Invalid workflow variables: \(error.localizedDescription)"
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
    idField.placeholderString = "management-id"
    let nameField = NSTextField(string: displayNameValue)
    nameField.placeholderString = "Display name"
    let stack = NSStackView(views: [
      NSTextField(labelWithString: "Management ID"),
      idField,
      NSTextField(labelWithString: "Display Name"),
      nameField
    ])
    stack.orientation = .vertical
    stack.spacing = 6
    stack.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
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
      status = "Management ID is required"
      refreshDaemonWorkflowWindow()
      return nil
    }
    let displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return InstancePromptResult(identity: identity, displayName: displayName.isEmpty ? nil : displayName)
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

  private func jsonText(from object: JSONObject) -> String {
    guard !object.isEmpty,
      let data = try? JSONEncoder().encode(JSONValue.object(object)),
      let text = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return text
  }

  private func parseJSONObject(_ text: String) throws -> JSONObject {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return [:]
    }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
    guard case let .object(object) = value else {
      throw NSError(domain: "RielaApp", code: 3, userInfo: [NSLocalizedDescriptionKey: "variables must be a JSON object"])
    }
    return object
  }
}
#endif
