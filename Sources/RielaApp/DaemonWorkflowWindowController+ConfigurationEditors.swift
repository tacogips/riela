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
    activeConfigurationEditorTargets = []
    let textView = configurationTextView(text: environmentText(from: row.preference.environmentVariables))
    inlineEnvironmentTextView = textView
    showConfigurationEditor(
      title: "Environment Variables",
      message: "Inline values override matching values from the selected .env file.",
      bodyViews: [
        effectiveEnvironmentView(values: configuredEnvironmentValues(candidate)),
        labeledEditor(
          title: "Inline Environment",
          caption: "Values entered here are stored in this profile's instance state on disk.",
          textView: textView
        )
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
    activeConfigurationEditorTargets = []
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
    activeConfigurationEditorTargets = []
    let sourceTextView = configurationTextView(text: eventSourceTemplate(for: candidate))
    let bindingTextView = configurationTextView(text: eventBindingTemplate(for: candidate, sourceId: defaultEventSourceId(for: candidate)))
    eventSourceTextView = sourceTextView
    eventBindingTextView = bindingTextView
    let modeControl = NSSegmentedControl(labels: ["Form", "JSON"], trackingMode: .selectOne, target: self, action: #selector(eventSourceModeChanged))
    modeControl.selectedSegment = 0
    eventSourceModeControl = modeControl
    let kindPopup = NSPopUpButton()
    kindPopup.addItems(withTitles: RielaAppDaemonWorkflowDiscovery.daemonSourceKinds())
    kindPopup.selectItem(withTitle: "telegram-gateway")
    eventSourceKindPopup = kindPopup
    let sourceIdField = NSTextField(string: defaultEventSourceId(for: candidate))
    sourceIdField.bezelStyle = .roundedBezel
    eventSourceIdField = sourceIdField
    let hint = NSTextField(labelWithString: "telegram-gateway receives Telegram messages; requires TELEGRAM_BOT_TOKEN in this instance's environment.")
    hint.textColor = .secondaryLabelColor
    hint.lineBreakMode = .byWordWrapping
    hint.maximumNumberOfLines = 2
    let formRows = NSStackView(views: [
      settingsTextRow(title: "Kind", value: kindPopup),
      settingsTextRow(title: "Source ID", value: sourceIdField),
      hint,
      NSTextField(labelWithString: "The event's payload is passed to the workflow as event input.")
    ])
    formRows.orientation = .vertical
    formRows.alignment = .width
    formRows.spacing = 8
    eventSourceFormView = formRows
    let jsonStack = NSStackView(views: [
      labeledEditor(title: "Source JSON", textView: sourceTextView),
      labeledEditor(title: "Binding JSON", textView: bindingTextView)
    ])
    jsonStack.orientation = .vertical
    jsonStack.alignment = .width
    jsonStack.spacing = 12
    jsonStack.isHidden = true
    eventSourceJSONView = jsonStack
    showConfigurationEditor(
      title: "Event Sources",
      message: "Register a source and binding under this workflow's .riela-events directory.",
      bodyViews: [
        modeControl,
        eventSourceSummaryView(candidate: candidate),
        formRows,
        jsonStack
      ],
      primaryTitle: "Register",
      primaryAction: #selector(saveEventSourceEditor)
    )
  }

  @objc func cancelConfigurationEditor() {
    activeConfigurationEditorTargets = []
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
    activeConfigurationEditorTargets = []
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
    activeConfigurationEditorTargets = []
    showInstanceDetailOverview()
  }

  @objc func saveEventSourceEditor() {
    guard let identity = selectedRowForEditor()?.id,
      let sourceJSON = currentEventSourceJSON(),
      let bindingJSON = currentEventBindingJSON()
    else {
      return
    }
    if let error = onRegisterEventSource(identity, sourceJSON, bindingJSON) {
      showEditorError(error)
      return
    }
    activeConfigurationEditorTargets = []
    showInstanceDetailOverview()
  }

  @objc func eventSourceModeChanged() {
    guard let modeControl = eventSourceModeControl else {
      return
    }
    let usesJSON = modeControl.selectedSegment == 1
    if usesJSON {
      syncEventSourceJSONFromForm()
    }
    eventSourceFormView?.isHidden = usesJSON
    eventSourceJSONView?.isHidden = !usesJSON
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

  private func labeledEditor(title: String, caption: String? = nil, textView: NSTextView) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(scroll)
    scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
    var views: [NSView] = [titleLabel, scroll]
    if let caption {
      let captionLabel = NSTextField(labelWithString: caption)
      captionLabel.textColor = .secondaryLabelColor
      captionLabel.font = .systemFont(ofSize: 11)
      captionLabel.lineBreakMode = .byWordWrapping
      captionLabel.maximumNumberOfLines = 2
      views.append(captionLabel)
    }
    let stack = NSStackView(views: views)
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
    let textView = configurationTextView(text: RielaAppEnvironmentValueFormatter.text(values: values, revealsValues: false))
    textView.isEditable = false
    let showValues = NSButton(checkboxWithTitle: "Show Values", target: nil, action: nil)
    let target = EnvironmentRevealToggleTarget(textView: textView, values: values, checkbox: showValues)
    showValues.target = target
    showValues.action = #selector(target.toggle)
    activeConfigurationEditorTargets.append(target)
    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    rielaAppConfigureGroupedTextScroll(scroll)
    scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
    let stack = NSStackView(views: [title, showValues, scroll])
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

  private func settingsTextRow(title: String, value: NSView) -> NSView {
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

  private func currentEventSourceJSON() -> String? {
    guard eventSourceModeControl?.selectedSegment != 1 else {
      return eventSourceTextView?.string
    }
    return eventSourceJSONFromForm()
  }

  private func currentEventBindingJSON() -> String? {
    guard eventSourceModeControl?.selectedSegment != 1 else {
      return eventBindingTextView?.string
    }
    return eventBindingJSONFromForm()
  }

  private func syncEventSourceJSONFromForm() {
    eventSourceTextView?.string = eventSourceJSONFromForm() ?? "{}"
    eventBindingTextView?.string = eventBindingJSONFromForm() ?? "{}"
  }

  private func eventSourceJSONFromForm() -> String? {
    guard let sourceId = eventSourceIdField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      !sourceId.isEmpty
    else {
      return nil
    }
    let kind = eventSourceKindPopup?.selectedItem?.title ?? RielaAppDaemonWorkflowDiscovery.daemonSourceKinds().first ?? ""
    let provider = kind.replacingOccurrences(of: "-gateway", with: "")
    return prettyJSONText([
      "id": sourceId,
      "kind": kind,
      "provider": provider
    ])
  }

  private func eventBindingJSONFromForm() -> String? {
    guard let row = selectedRowForEditor(), let candidate = row.candidate,
      let sourceId = eventSourceIdField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      !sourceId.isEmpty
    else {
      return nil
    }
    return eventBindingTemplate(for: candidate, sourceId: sourceId)
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
