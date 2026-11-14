#if os(macOS)
import AppKit
import RielaViewer

extension WorkflowViewerWindowController {
  func expandAll() {
    for node in state?.nodes ?? [] {
      outlineView.expandItem(node, expandChildren: true)
    }
  }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if let node = item as? WorkflowViewerNode {
      return node.children.count
    }
    return state?.nodes.count ?? 0
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if let node = item as? WorkflowViewerNode {
      return node.children[index]
    }
    return state?.nodes[index] ?? WorkflowViewerNode(id: "missing", nodeId: "missing", title: "missing", state: .failed)
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? WorkflowViewerNode)?.children.isEmpty == false
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let node = item as? WorkflowViewerNode else {
      return nil
    }
    let identifier = NSUserInterfaceItemIdentifier("workflow-node-cell")
    let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? RielaAppTableSelectionCellView
      ?? RielaAppTableSelectionCellView()
    cell.identifier = identifier
    cell.configureSelection(
      tableView: outlineView,
      row: outlineView.row(forItem: node),
      role: .button,
      accessibilityLabel: node.title,
      accessibilityValue: stateAccessibilityLabel(node.state),
      accessibilityHelp: "Show workflow node details",
      actionTarget: self,
      action: #selector(workflowTreeRowPressed(_:))
    )
    let imageView = cell.imageView ?? NSImageView()
    let field = cell.textField ?? NSTextField(labelWithString: "")
    imageView.translatesAutoresizingMaskIntoConstraints = false
    field.translatesAutoresizingMaskIntoConstraints = false
    if imageView.superview == nil {
      cell.addSubview(imageView)
      cell.imageView = imageView
      NSLayoutConstraint.activate([
        imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        imageView.widthAnchor.constraint(equalToConstant: 12),
        imageView.heightAnchor.constraint(equalToConstant: 12)
      ])
    }
    if field.superview == nil {
      cell.addSubview(field)
      cell.textField = field
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
      ])
    }
    imageView.image = NSImage(
      systemSymbolName: stateSymbolName(node.state),
      accessibilityDescription: stateAccessibilityLabel(node.state)
    )
    imageView.contentTintColor = color(for: node.state)
    field.stringValue = node.title
    field.textColor = .labelColor
    field.font = node.state == .active ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
    return cell
  }

  @objc func workflowTreeRowPressed(_ sender: NSOutlineView) {
    outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: sender))
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    let row = outlineView.selectedRow
    guard row >= 0, let node = outlineView.item(atRow: row) as? WorkflowViewerNode else {
      return
    }
    selectedNodeId = node.id
    updateDetails()
  }

  func stateSymbolName(_ state: WorkflowViewerNodeRuntimeState) -> String {
    switch state {
    case .active:
      "circle.fill"
    case .completed:
      "checkmark.circle.fill"
    case .failed:
      "xmark.circle.fill"
    case .idle:
      "circle"
    }
  }

  func stateAccessibilityLabel(_ state: WorkflowViewerNodeRuntimeState) -> String {
    switch state {
    case .active:
      "Running"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    case .idle:
      "Idle"
    }
  }

  func color(for state: WorkflowViewerNodeRuntimeState) -> NSColor {
    switch state {
    case .active:
      .systemGreen
    case .completed:
      .secondaryLabelColor
    case .failed:
      .systemRed
    case .idle:
      .labelColor
    }
  }
}
#endif
