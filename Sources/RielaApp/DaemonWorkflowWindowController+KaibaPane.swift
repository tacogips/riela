#if os(macOS)
import AppKit
import RielaAppSupport
import RielaKaibaSupport

/// App-visible Kaiba status copy is intentionally closed. Server, transport,
/// endpoint, and credential diagnostics must never be forwarded into labels,
/// alerts, accessibility values, or status history.
enum RielaAppKaibaStatus: Sendable {
  case saveFailed
  case defaultChangeFailed
  case removalReferencesUnavailable
  case removeFailed
  case updateFailed
  case bindingSaveFailed
  case readiness(KaibaInstanceLastTestStatus)
  case readinessFailed

  var text: String {
    switch self {
    case .saveFailed:
      "Kaiba instance could not be saved. Check the display name, endpoint, and environment-variable name."
    case .defaultChangeFailed:
      "Kaiba default could not be changed. Select an enabled instance."
    case .removalReferencesUnavailable:
      "Kaiba removal is unavailable because workflow references could not be checked."
    case .removeFailed:
      "Kaiba instance could not be removed. Refresh and try again."
    case .updateFailed:
      "Kaiba instance could not be updated. Refresh and try again."
    case .bindingSaveFailed:
      "Kaiba node binding could not be saved. Refresh and try again."
    case let .readiness(status):
      "Kaiba readiness: \(status.rawValue)"
    case .readinessFailed:
      "Kaiba readiness could not be completed. Check the configured instance and credential environment variable."
    }
  }
}

@MainActor
extension DaemonWorkflowWindowController {
  /// The App deliberately delegates catalog policy to RielaKaibaSupport. This
  /// pane shows only safe endpoint/auth-reference state, never bearer values.
  func rebuildKaibaOverviewView() {
    let instances: [KaibaInstance]
    do {
      instances = try kaibaInstanceController.list()
    } catch {
      kaibaOverviewView = kaibaMessageView("Kaiba instances are unavailable. Repair ~/.riela/kaiba/instances.json, then refresh.")
      return
    }
    if instances.isEmpty {
      let add = kaibaAddButton()
      kaibaOverviewView = kaibaMessageView(
        "No Kaiba API instances. Add one to configure Kaiba nodes.",
        actions: [add]
      )
      return
    }
    let rows = instances.map(kaibaInstanceRow)
    let add = kaibaAddButton()
    let stack = settingsDocumentStack(views: [add, rielaAppSettingsSection(rows: rows)])
    let scroll = settingsScrollView(documentStack: stack, topInset: 0)
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = []
    rielaAppConfigureGroupedListScroll(scroll)
    kaibaOverviewView = scroll
  }

  private func kaibaMessageView(_ message: String, actions: [NSView] = []) -> NSView {
    let label = NSTextField(wrappingLabelWithString: message)
    label.textColor = .secondaryLabelColor
    label.setAccessibilityLabel("Kaiba API Instances")
    let stack = settingsDocumentStack(views: [label] + actions)
    let scroll = settingsScrollView(documentStack: stack, topInset: 0)
    scroll.translatesAutoresizingMaskIntoConstraints = true
    scroll.autoresizingMask = []
    return scroll
  }

  private func kaibaInstanceRow(_ instance: KaibaInstance) -> NSView {
    let title = NSTextField(labelWithString: instance.name + (instance.isDefault ? " (Default)" : ""))
    title.font = .systemFont(ofSize: 14, weight: .semibold)
    let credential = instance.authentication.credentialEnvironmentVariable.map { "Bearer: \($0)" } ?? "Unauthenticated"
    let detail = NSTextField(wrappingLabelWithString: "\(instance.endpoint)\n\(credential) · \(instance.enabled ? "Enabled" : "Disabled") · \(instance.lastTest.status.rawValue)")
    detail.textColor = .secondaryLabelColor
    let test = kaibaButton(
      symbol: "checkmark.circle", label: "Test Kaiba instance \(instance.name)",
      action: #selector(testKaibaInstance(_:)), instance: instance
    )
    test.isEnabled = instance.enabled
    let edit = kaibaButton(
      symbol: "pencil", label: "Edit Kaiba instance \(instance.name)",
      action: #selector(editKaibaInstance(_:)), instance: instance
    )
    let toggle = kaibaButton(
      symbol: instance.enabled ? "pause.circle" : "play.circle",
      label: "\(instance.enabled ? "Disable" : "Enable") Kaiba instance \(instance.name)",
      action: #selector(toggleKaibaInstance(_:)), instance: instance
    )
    let makeDefault = kaibaButton(
      symbol: "star", label: "Set \(instance.name) as default Kaiba instance",
      action: #selector(setDefaultKaibaInstance(_:)), instance: instance
    )
    makeDefault.isEnabled = instance.enabled && !instance.isDefault
    let remove = kaibaButton(
      symbol: "trash", label: "Remove Kaiba instance \(instance.name)",
      action: #selector(removeKaibaInstance(_:)), instance: instance
    )
    let vertical = NSStackView(views: [title, detail])
    vertical.orientation = .vertical
    vertical.alignment = .leading
    let actions = NSStackView(views: [test, edit, toggle, makeDefault, remove])
    actions.orientation = .horizontal
    actions.spacing = 6
    let row = NSStackView(views: [vertical, actions])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    vertical.setContentHuggingPriority(.defaultLow, for: .horizontal)
    test.setContentHuggingPriority(.required, for: .horizontal)
    return row
  }

  private func kaibaButton(
    symbol: String,
    label: String,
    action: Selector,
    instance: KaibaInstance
  ) -> NSButton {
    let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
    button.title = ""
    button.identifier = NSUserInterfaceItemIdentifier(instance.id)
    button.bezelStyle = .texturedRounded
    button.imagePosition = .imageOnly
    button.toolTip = label
    button.setAccessibilityLabel(label)
    return button
  }

  private func kaibaAddButton() -> NSButton {
    let label = "Add Kaiba API instance"
    let button = NSButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: label) ?? NSImage(),
      target: self,
      action: #selector(addKaibaInstance(_:))
    )
    button.title = ""
    button.bezelStyle = .texturedRounded
    button.imagePosition = .imageOnly
    button.toolTip = label
    button.setAccessibilityLabel(label)
    return button
  }

  @objc private func addKaibaInstance(_ sender: NSButton) {
    presentKaibaEditor(existing: nil)
  }

  @objc private func editKaibaInstance(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue,
          let instance = try? kaibaInstanceController.list().first(where: { $0.id == id }) else { return }
    presentKaibaEditor(existing: instance)
  }

  private func presentKaibaEditor(existing: KaibaInstance?) {
    let name = NSTextField(string: existing?.name ?? "")
    name.placeholderString = "Display name"
    let endpoint = NSTextField(string: existing?.endpoint ?? "http://127.0.0.1:8787")
    endpoint.placeholderString = "https://kaiba.example.com/graphql"
    let authentication = NSPopUpButton(frame: .zero, pullsDown: false)
    authentication.addItems(withTitles: ["Unauthenticated", "Bearer environment variable"])
    let credential = NSTextField(string: existing?.authentication.credentialEnvironmentVariable ?? "")
    credential.placeholderString = "KAIBA_API_KEY"
    credential.isHidden = existing?.authentication.credentialEnvironmentVariable == nil
    authentication.selectItem(at: existing?.authentication.credentialEnvironmentVariable == nil ? 0 : 1)
    authentication.target = self
    authentication.action = #selector(kaibaAuthenticationSelectionChanged(_:))
    credential.identifier = NSUserInterfaceItemIdentifier("kaibaCredentialEnvironmentVariable")
    let enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    enabled.state = existing?.enabled == false ? .off : .on
    let insecure = NSButton(checkboxWithTitle: "Allow insecure HTTP", target: nil, action: nil)
    insecure.state = existing?.allowInsecureHTTP == true ? .on : .off
    let remoteUnauthenticated = NSButton(checkboxWithTitle: "Allow remote unauthenticated", target: nil, action: nil)
    remoteUnauthenticated.state = existing?.allowRemoteUnauthenticated == true ? .on : .off
    let form = NSStackView(views: [name, endpoint, authentication, credential, enabled, insecure, remoteUnauthenticated])
    form.orientation = .vertical
    form.spacing = 8
    let alert = NSAlert()
    alert.messageText = existing == nil ? "Add Kaiba API Instance" : "Edit Kaiba API Instance"
    alert.informativeText = "Use an endpoint and, if required, the name of a bearer-token environment variable. Token values are never entered or stored here."
    alert.accessoryView = form
    alert.addButton(withTitle: existing == nil ? "Add" : "Save")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let auth: KaibaInstanceAuthentication = authentication.indexOfSelectedItem == 1
      ? .bearer(environmentVariable: credential.stringValue)
      : .unauthenticated
    let candidate = KaibaInstance(
      id: existing?.id ?? UUID().uuidString.lowercased(),
      name: name.stringValue,
      endpoint: endpoint.stringValue,
      authentication: auth,
      enabled: enabled.state == .on,
      isDefault: existing?.isDefault ?? false,
      allowInsecureHTTP: insecure.state == .on,
      allowRemoteUnauthenticated: remoteUnauthenticated.state == .on,
      lastTest: existing?.lastTest ?? .init()
    )
    do {
      if let existing {
        _ = try kaibaInstanceController.update(candidate, expected: existing)
      } else {
        _ = try kaibaInstanceController.add(candidate)
      }
      rebuildKaibaOverviewView()
      if activeSidebarPane == .kaiba { showContentPane(kaibaOverviewView) }
    } catch {
      presentKaibaStatus(.saveFailed)
    }
  }

  @objc private func kaibaAuthenticationSelectionChanged(_ sender: NSPopUpButton) {
    guard let credential = sender.superview?.subviews.compactMap({ $0 as? NSTextField }).first(where: {
      $0.identifier == NSUserInterfaceItemIdentifier("kaibaCredentialEnvironmentVariable")
    }) else { return }
    credential.isHidden = sender.indexOfSelectedItem == 0
  }

  @objc private func toggleKaibaInstance(_ sender: NSButton) {
    guard let instance = kaibaInstance(for: sender) else { return }
    var updated = instance
    updated.enabled.toggle()
    saveKaibaUpdate(updated, expected: instance)
  }

  @objc private func setDefaultKaibaInstance(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    do {
      _ = try kaibaInstanceController.setDefault(id: id)
      rebuildKaibaOverviewView()
      if activeSidebarPane == .kaiba { showContentPane(kaibaOverviewView) }
    } catch {
      presentKaibaStatus(.defaultChangeFailed)
    }
  }

  @objc private func removeKaibaInstance(_ sender: NSButton) {
    guard let instance = kaibaInstance(for: sender) else { return }
    let references: [KaibaBindingReference]
    do {
      references = try kaibaInstanceController.removalReferences(id: instance.id)
    } catch {
      presentKaibaStatus(.removalReferencesUnavailable)
      return
    }
    let alert = NSAlert()
    alert.messageText = "Remove \(instance.name)?"
    alert.informativeText = references.isEmpty
      ? "This removes the configured Kaiba instance."
      : "\(references.count) workflow binding(s) still reference this instance. Remove Anyway leaves those bindings unresolved."
    alert.addButton(withTitle: references.isEmpty ? "Remove" : "Remove Anyway")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      _ = try kaibaInstanceController.remove(id: instance.id, force: !references.isEmpty)
      rebuildKaibaOverviewView()
      if activeSidebarPane == .kaiba { showContentPane(kaibaOverviewView) }
    } catch {
      presentKaibaStatus(.removeFailed)
    }
  }

  private func kaibaInstance(for sender: NSButton) -> KaibaInstance? {
    guard let id = sender.identifier?.rawValue else { return nil }
    return try? kaibaInstanceController.list().first(where: { $0.id == id })
  }

  private func saveKaibaUpdate(_ updated: KaibaInstance, expected: KaibaInstance) {
    do {
      _ = try kaibaInstanceController.update(updated, expected: expected)
      rebuildKaibaOverviewView()
      if activeSidebarPane == .kaiba { showContentPane(kaibaOverviewView) }
    } catch {
      presentKaibaStatus(.updateFailed)
    }
  }

  @objc private func testKaibaInstance(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    sender.isEnabled = false
    let controller = kaibaInstanceController
    let environment = ProcessInfo.processInfo.environment
    Task.detached { [weak self] in
      let status: RielaAppKaibaStatus
      do {
        let result = try await controller.test(id: id, environment: environment)
        status = .readiness(result.status)
      } catch {
        status = .readinessFailed
      }
      await MainActor.run {
        sender.isEnabled = true
        self?.presentKaibaStatus(status)
        self?.rebuildKaibaOverviewView()
        if self?.activeSidebarPane == .kaiba { self?.showContentPane(self?.kaibaOverviewView) }
      }
    }
  }

  func presentKaibaStatus(_ status: RielaAppKaibaStatus) {
    statusBannerView.configure(message: .classified(status.text), history: [])
    statusBannerView.isHidden = false
    settingsRootView?.needsLayout = true
  }
}
#endif
