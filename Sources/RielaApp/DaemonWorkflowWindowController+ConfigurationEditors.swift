#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore

extension DaemonWorkflowWindowController {
  func showInlineEnvironmentEditor() {
    guard let row = selectedRowForEditor(), let candidate = row.candidate else {
      return
    }
    instanceDetailPane = .inlineEnvironment
    let textView = configurationTextView(text: environmentText(from: row.preference.environmentVariables))
    inlineEnvironmentTextView = textView
    showConfigurationEditor(
      title: "Environment Variables",
      message: "Inline values override matching values from the selected .env file.",
      bodyViews: [
        effectiveEnvironmentView(values: configuredEnvironmentValues(candidate)),
        labeledEditor(title: "Inline Environment", textView: textView)
      ],
      primaryTitle: "Save",
      primaryAction: #selector(saveInlineEnvironmentEditor)
    )
  }

  func showWorkflowVariablesEditor() {
    guard let row = selectedRowForEditor() else {
      return
    }
    instanceDetailPane = .workflowVariables
    let textView = configurationTextView(text: workflowVariablesText(from: row.preference.defaultVariables))
    workflowVariablesTextView = textView
    showConfigurationEditor(
      title: "Workflow Variables",
      message: "These values are passed as the final default variables for this instance.",
      bodyViews: [
        labeledEditor(title: "Effective Workflow Variables", textView: textView)
      ],
      primaryTitle: "Save",
      primaryAction: #selector(saveWorkflowVariablesEditor)
    )
  }

  func showEventSourceEditor() {
    guard let row = selectedRowForEditor(), let candidate = row.candidate else {
      return
    }
    instanceDetailPane = .eventSources
    let sourceTextView = configurationTextView(text: eventSourceTemplate(for: candidate))
    let bindingTextView = configurationTextView(text: eventBindingTemplate(for: candidate, sourceId: defaultEventSourceId(for: candidate)))
    eventSourceTextView = sourceTextView
    eventBindingTextView = bindingTextView
    showConfigurationEditor(
      title: "Event Sources",
      message: "Register a source and binding under this workflow's .riela-events directory.",
      bodyViews: [
        eventSourceSummaryView(candidate: candidate),
        labeledEditor(title: "Source JSON", textView: sourceTextView),
        labeledEditor(title: "Binding JSON", textView: bindingTextView)
      ],
      primaryTitle: "Register",
      primaryAction: #selector(saveEventSourceEditor)
    )
  }

  @objc func cancelConfigurationEditor() {
    showInstanceDetailOverview()
  }

  @objc func saveInlineEnvironmentEditor() {
    guard let identity = selectedRowForEditor()?.id, let text = inlineEnvironmentTextView?.string else {
      return
    }
    if let error = onSaveEnvironmentVariables(identity, text) {
      showEditorError(error)
      return
    }
    showInstanceDetailOverview()
  }

  @objc func saveWorkflowVariablesEditor() {
    guard let identity = selectedRowForEditor()?.id, let text = workflowVariablesTextView?.string else {
      return
    }
    if let error = onSaveWorkflowVariables(identity, text) {
      showEditorError(error)
      return
    }
    showInstanceDetailOverview()
  }

  @objc func saveEventSourceEditor() {
    guard let identity = selectedRowForEditor()?.id,
      let sourceJSON = eventSourceTextView?.string,
      let bindingJSON = eventBindingTextView?.string
    else {
      return
    }
    if let error = onRegisterEventSource(identity, sourceJSON, bindingJSON) {
      showEditorError(error)
      return
    }
    showInstanceDetailOverview()
  }

  private func selectedRowForEditor() -> ConfiguredWorkflowInstanceRow? {
    let row = instanceTable.selectedRow
    guard row >= 0 else {
      return nil
    }
    let rows = instanceRows
    guard rows.indices.contains(row) else {
      return nil
    }
    return rows[row]
  }

  private func showConfigurationEditor(
    title: String,
    message: String,
    bodyViews: [NSView],
    primaryTitle: String,
    primaryAction: Selector
  ) {
    configurationEditorView?.removeFromSuperview()
    guard let contentHost else {
      return
    }
    isShowingAddInstanceSelection = false
    isShowingWorkflowSourceDetail = false
    navigationTitleLabel.stringValue = title
    let editor = configurationEditorView(
      title: title,
      message: message,
      bodyViews: bodyViews,
      primaryTitle: primaryTitle,
      primaryAction: primaryAction
    )
    editor.frame = contentHost.bounds
    editor.autoresizingMask = [.width, .height]
    configurationEditorView = editor
    showContentPane(editor)
    updateNavigationState()
    updateSidebarSelection()
  }

  private func configurationEditorView(
    title: String,
    message: String,
    bodyViews: [NSView],
    primaryTitle: String,
    primaryAction: Selector
  ) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
    titleLabel.lineBreakMode = .byTruncatingTail
    let messageLabel = NSTextField(labelWithString: message)
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.lineBreakMode = .byWordWrapping
    messageLabel.maximumNumberOfLines = 2
    let statusLabel = NSTextField(labelWithString: "")
    statusLabel.textColor = .systemRed
    statusLabel.lineBreakMode = .byWordWrapping
    statusLabel.maximumNumberOfLines = 2
    configurationEditorStatusLabel = statusLabel

    let stack = NSStackView(views: [titleLabel, messageLabel, statusLabel] + bodyViews)
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor)
    ])

    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.borderType = .noBorder
    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let saveButton = NSButton(title: primaryTitle, target: self, action: primaryAction)
    saveButton.bezelStyle = .rounded
    let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelConfigurationEditor))
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let buttons = NSStackView(views: [spacer, cancelButton, saveButton])
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 8
    buttons.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(scroll)
    container.addSubview(buttons)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: container.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14)
    ])
    return container
  }

  private func labeledEditor(title: String, textView: NSTextView) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(scroll)
    scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
    let stack = NSStackView(views: [titleLabel, scroll])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 6
    return stack
  }

  private func configurationTextView(text: String) -> NSTextView {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 190))
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.textColor = .labelColor
    textView.backgroundColor = .controlBackgroundColor
    textView.drawsBackground = true
    textView.string = text
    return textView
  }

  private func effectiveEnvironmentView(values: [RielaAppConfiguredEnvironmentValue]) -> NSView {
    let title = NSTextField(labelWithString: "Effective Configured Environment")
    title.font = .systemFont(ofSize: 13, weight: .medium)
    let text = values.isEmpty
      ? "No .env or inline environment values are configured."
      : values
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .map { "\($0.name)=\($0.value) (\($0.source))" }
        .joined(separator: "\n")
    let textView = configurationTextView(text: text)
    textView.isEditable = false
    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(scroll)
    scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
    let stack = NSStackView(views: [title, scroll])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 6
    return stack
  }

  private func eventSourceSummaryView(candidate: RielaAppDaemonWorkflowCandidate) -> NSView {
    let root = NSTextField(labelWithString: candidate.eventRoot ?? "\(candidate.workflowDirectory)/.riela-events")
    root.lineBreakMode = .byTruncatingMiddle
    let sources = NSTextField(labelWithString: candidate.eventSourceSummary)
    sources.lineBreakMode = .byTruncatingMiddle
    let rows = NSStackView(views: [
      settingsTextRow(title: "Event Root", value: root),
      settingsTextRow(title: "Current Sources", value: sources)
    ])
    rows.orientation = .vertical
    rows.alignment = .width
    rows.spacing = 8
    return rows
  }

  private func settingsTextRow(title: String, value: NSTextField) -> NSView {
    value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [rielaAppSettingsTitleLabel(title, maxWidth: 130), value])
    row.orientation = .horizontal
    row.spacing = 8
    row.alignment = .firstBaseline
    return rielaAppSettingsRow(row)
  }

  private func showEditorError(_ error: String) {
    configurationEditorStatusLabel?.stringValue = error
    NSApp.requestUserAttention(.informationalRequest)
  }

  private func environmentText(from variables: [String: String]) -> String {
    variables.keys.sorted().map { key in
      "\(key)=\(variables[key] ?? "")"
    }.joined(separator: "\n")
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

  private func jsonText(from value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
      let text = String(data: data, encoding: .utf8)
    else {
      return "null"
    }
    return text
  }

  private func defaultEventSourceId(for candidate: RielaAppDaemonWorkflowCandidate) -> String {
    sanitizedIdentifier("\(candidate.workflowId)-source")
  }

  private func eventSourceTemplate(for candidate: RielaAppDaemonWorkflowCandidate) -> String {
    prettyJSONText([
      "id": defaultEventSourceId(for: candidate),
      "kind": "telegram-gateway",
      "provider": "telegram"
    ])
  }

  private func eventBindingTemplate(for candidate: RielaAppDaemonWorkflowCandidate, sourceId: String) -> String {
    prettyJSONText([
      "id": "\(sourceId)-to-workflow",
      "sourceId": sourceId,
      "workflowName": candidate.workflowId,
      "inputMapping": [
        "mode": "event-input"
      ]
    ])
  }

  private func prettyJSONText(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return text
  }

  private func sanitizedIdentifier(_ rawValue: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    let mapped = rawValue.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_ :"))
  }
}
#endif
