#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore
import RielaKaibaSupport

private struct KaibaNodeBindingLoadResult: Sendable {
  let workflow: WorkflowDefinition?
  let instances: [KaibaInstance]?
}

@MainActor
extension DaemonWorkflowWindowController {
  func buildKaibaNodeBindingViews() -> [NSView] {
    kaibaNodeBindingsStack.orientation = .vertical
    kaibaNodeBindingsStack.alignment = .leading
    kaibaNodeBindingsStack.spacing = 8

    let caption = settingsSectionCaption("Kaiba Nodes")
    let section = rielaAppSettingsSection(rows: [kaibaNodeBindingsStack])
    caption.isHidden = true
    section.isHidden = true
    kaibaNodeBindingsCaption = caption
    kaibaNodeBindingsSection = section
    return [caption, section]
  }

  func updateKaibaNodeBindings(for row: ConfiguredWorkflowInstanceRow) {
    clearKaibaNodeBindingRows()
    kaibaNodeBindingLoadTask?.cancel()
    kaibaNodeBindingLoadRevision += 1
    let revision = kaibaNodeBindingLoadRevision
    guard let candidate = row.candidate else {
      setKaibaNodeBindingsHidden(true)
      return
    }
    kaibaNodeBindingsStack.addArrangedSubview(kaibaBindingMessage("Loading Kaiba node bindings…"))
    setKaibaNodeBindingsHidden(false)

    let workflowDirectory = candidate.workflowDirectory
    let controller = kaibaInstanceController
    let identity = row.id
    kaibaNodeBindingLoadTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        let workflow = Self.workflowDefinition(at: workflowDirectory)
        let instances = try? controller.list()
        return KaibaNodeBindingLoadResult(workflow: workflow, instances: instances)
      }.value
      guard !Task.isCancelled,
            let self,
            self.kaibaNodeBindingLoadRevision == revision,
            self.selectedRow()?.id == identity else {
        return
      }
      self.renderKaibaNodeBindings(result, preference: row.preference)
    }
  }

  @objc func selectKaibaNodeBinding(_ sender: NSPopUpButton) {
    guard let row = selectedRow(),
          let nodeID = sender.identifier?.rawValue else { return }
    let instanceID = sender.selectedItem?.representedObject as? String
    let authoredBinding = sender.accessibilityIdentifier() == "kaiba-authored-binding"
    guard onSaveKaibaNodeBinding(row.id, nodeID, instanceID, authoredBinding) else {
      presentKaibaStatus(.bindingSaveFailed)
      return
    }
  }

  nonisolated static func workflowDefinition(at directory: String) -> WorkflowDefinition? {
    let workflowURL = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("workflow.json")
    guard let data = try? Data(contentsOf: workflowURL) else { return nil }
    return validateAuthoredWorkflowData(data).workflow
  }

  private func renderKaibaNodeBindings(
    _ result: KaibaNodeBindingLoadResult,
    preference: RielaAppDaemonWorkflowPreference
  ) {
    clearKaibaNodeBindingRows()
    guard let workflow = result.workflow else {
      setKaibaNodeBindingsHidden(true)
      return
    }
    let rows = RielaAppKaibaBindingController.rows(
      workflow: workflow,
      preference: preference,
      instances: result.instances ?? []
    )
    guard !rows.isEmpty else {
      setKaibaNodeBindingsHidden(true)
      return
    }
    guard result.instances != nil else {
      kaibaNodeBindingsStack.addArrangedSubview(kaibaBindingMessage("Kaiba instance catalog is unavailable. Open Kaiba settings and repair the catalog."))
      setKaibaNodeBindingsHidden(false)
      return
    }
    for row in rows {
      kaibaNodeBindingsStack.addArrangedSubview(kaibaNodeBindingRow(row))
    }
    setKaibaNodeBindingsHidden(false)
  }

  private func kaibaNodeBindingRow(_ binding: RielaAppKaibaNodeBindingRow) -> NSView {
    let title = rielaAppSettingsTitleLabel(binding.nodeID, maxWidth: 180)
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.identifier = NSUserInterfaceItemIdentifier(binding.nodeID)
    popup.target = self
    popup.action = #selector(selectKaibaNodeBinding(_:))
    popup.setAccessibilityLabel("Kaiba instance for node \(binding.nodeID)")
    popup.setAccessibilityHelp("Select the named Kaiba API instance for this node, or reset it to the catalog default.")
    if binding.usesAuthoredBinding {
      popup.setAccessibilityIdentifier("kaiba-authored-binding")
    }
    for choice in binding.choices {
      popup.addItem(withTitle: choice.title)
      popup.lastItem?.representedObject = choice.instanceID
      popup.lastItem?.isEnabled = choice.isEnabled
    }
    if let effectiveID = binding.effectiveInstanceID,
       let item = popup.itemArray.first(where: { ($0.representedObject as? String) == effectiveID }) {
      popup.select(item)
    } else {
      popup.selectItem(at: 0)
    }

    let detail = NSTextField(wrappingLabelWithString: binding.detail)
    detail.textColor = .secondaryLabelColor
    detail.maximumNumberOfLines = 2
    detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let content = NSStackView(views: [popup, detail])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 3
    content.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = RielaAppSettingsRow(views: [title, content])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 12
    row.setAccessibilityElement(true)
    row.setAccessibilityRole(.group)
    row.setAccessibilityLabel("Kaiba node \(binding.nodeID)")
    row.setAccessibilityValue(detail.stringValue)
    return rielaAppSettingsRow(row)
  }

  private func kaibaBindingMessage(_ value: String) -> NSView {
    let label = NSTextField(wrappingLabelWithString: value)
    label.textColor = .secondaryLabelColor
    label.setAccessibilityLabel("Kaiba node bindings")
    return label
  }

  private func clearKaibaNodeBindingRows() {
    for view in kaibaNodeBindingsStack.arrangedSubviews {
      kaibaNodeBindingsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func setKaibaNodeBindingsHidden(_ hidden: Bool) {
    kaibaNodeBindingsCaption?.isHidden = hidden
    kaibaNodeBindingsSection?.isHidden = hidden
  }

  func updateKaibaWorkflowReadiness(for row: ConfiguredWorkflowInstanceRow) {
    kaibaWorkflowReadinessTask?.cancel()
    kaibaWorkflowReadinessRevision += 1
    let revision = kaibaWorkflowReadinessRevision
    let identity = row.id
    setKaibaStartActionEnabled(false, status: "Checking Kaiba readiness…")
    kaibaWorkflowReadinessTask = Task { [weak self] in
      guard let self else { return }
      let readiness = await onCheckKaibaWorkflowReadiness(identity)
      guard !Task.isCancelled,
            self.kaibaWorkflowReadinessRevision == revision,
            self.selectedRow()?.id == identity else {
        return
      }
      self.setKaibaStartActionEnabled(readiness.isStartAllowed, status: readiness.statusText)
    }
  }

  private func setKaibaStartActionEnabled(_ enabled: Bool, status: String?) {
    guard let row = startInstanceActionRow as? RielaAppSelectableSettingsRow else { return }
    row.setRielaAccessibilityEnabled(enabled)
    let help = status ?? "Run this instance and include it in future app launches."
    row.toolTip = help
    row.setAccessibilityHelp(help)
  }
}
#endif
