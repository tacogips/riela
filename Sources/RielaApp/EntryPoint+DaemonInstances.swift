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
    let existing = workflowVariablesText(from: daemonState.preference(for: identity).defaultVariables)
    guard let text = promptForMultilineValue(
      title: "Workflow Variables",
      message: "Enter key=value lines for \(candidate.displayName). Use key:=JSON for typed values.",
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
