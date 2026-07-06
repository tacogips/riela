#if os(macOS)
import AppKit
import RielaCore
import RielaViewer

final class WorkflowExecutionDetailPopover {
  @MainActor
  static func make(
    entry: WorkflowViewerTimelineEntry,
    messages: [WorkflowViewerMessage],
    dateFormatter: DateFormatter,
    durationFormatter: @escaping (TimeInterval?) -> String
  ) -> NSPopover {
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 520, height: 430)
    let controller = NSViewController()
    controller.view = DetailView(
      entry: entry,
      messages: messages,
      dateFormatter: dateFormatter,
      durationFormatter: durationFormatter
    )
    popover.contentViewController = controller
    return popover
  }
}

private final class DetailView: NSView {
  private let entry: WorkflowViewerTimelineEntry
  private let messages: [WorkflowViewerMessage]
  private let dateFormatter: DateFormatter
  private let durationFormatter: (TimeInterval?) -> String
  private let segmentedControl = NSSegmentedControl(labels: ["Log", "Inbox", "Outbox"], trackingMode: .selectOne, target: nil, action: nil)
  private let textView = NSTextView()

  init(
    entry: WorkflowViewerTimelineEntry,
    messages: [WorkflowViewerMessage],
    dateFormatter: DateFormatter,
    durationFormatter: @escaping (TimeInterval?) -> String
  ) {
    self.entry = entry
    self.messages = messages
    self.dateFormatter = dateFormatter
    self.durationFormatter = durationFormatter
    super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 430))
    build()
    showSelectedTab()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func build() {
    let header = headerView()
    segmentedControl.selectedSegment = 0
    segmentedControl.target = self
    segmentedControl.action = #selector(tabChanged)
    textView.isEditable = false
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.textColor = .labelColor
    textView.backgroundColor = .controlBackgroundColor
    textView.drawsBackground = true
    textView.textContainerInset = NSSize(width: 10, height: 10)
    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    rielaAppConfigureGroupedTextScroll(scroll)

    let stack = NSStackView(views: [header, segmentedControl, scroll])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
    ])
  }

  private func headerView() -> NSView {
    let title = NSTextField(labelWithString: entry.stepId)
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    let statusDot = NSTextField(labelWithString: "●")
    statusDot.textColor = statusColor(entry.status)
    let status = NSTextField(labelWithString: entry.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
    status.textColor = .secondaryLabelColor
    let statusRow = NSStackView(views: [statusDot, status])
    statusRow.orientation = .horizontal
    statusRow.spacing = 4
    let meta = NSTextField(wrappingLabelWithString: rielaAppMetadataText([
      "Node \(entry.nodeId)",
      "Attempt \(entry.attempt)",
      "Backend \(entry.backend?.rawValue ?? "-")",
      "Started \(dateFormatter.string(from: entry.startedAt))",
      "Ended \(entry.endedAt.map { dateFormatter.string(from: $0) } ?? "running")",
      "Duration \(durationFormatter(entry.duration))"
    ]))
    meta.font = .systemFont(ofSize: 11)
    meta.textColor = .secondaryLabelColor
    let views = entry.failureReason.map { failure in
      let failureLabel = NSTextField(wrappingLabelWithString: "Failure: \(failure)")
      failureLabel.textColor = .systemRed
      failureLabel.font = .systemFont(ofSize: 11)
      return [title, statusRow, meta, failureLabel]
    } ?? [title, statusRow, meta]
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 4
    return stack
  }

  @objc private func tabChanged() {
    showSelectedTab()
  }

  private func showSelectedTab() {
    switch segmentedControl.selectedSegment {
    case 1:
      setText(inboxText())
    case 2:
      setText(outboxText())
    default:
      setText(logText())
    }
  }

  private func setText(_ text: String) {
    textView.textStorage?.setAttributedString(NSAttributedString(
      string: text,
      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
    ))
  }

  private func logText() -> String {
    var lines: [String] = []
    if entry.backendEvents.isEmpty {
      lines.append("No backend events recorded.")
    } else {
      for event in entry.backendEvents.sorted(by: { $0.sequence < $1.sequence }) {
        lines.append([
          "#\(event.sequence)",
          dateFormatter.string(from: event.at),
          event.eventType,
          event.channel?.rawValue,
          event.toolName
        ].compactMap { $0 }.joined(separator: "  "))
        if let content = event.content, !content.isEmpty {
          lines.append(content)
        }
        lines.append("")
      }
    }
    if let total = entry.backendEventTotalCount, total > entry.backendEvents.count {
      lines.append("Showing most recent \(entry.backendEvents.count) of \(total) events. Run `riela session export <session-id>` for the full log.")
    }
    return lines.joined(separator: "\n")
  }

  private func inboxText() -> String {
    let inbox = messages
      .filter { $0.toStepId == entry.stepId }
      .sorted { ($0.createdOrder ?? 0, $0.id) < ($1.createdOrder ?? 0, $1.id) }
    return messagesText(inbox, empty: "Inbox is empty.")
  }

  private func outboxText() -> String {
    let outbox = messages
      .filter { $0.sourceStepExecutionId == entry.executionId }
      .sorted { ($0.createdOrder ?? 0, $0.id) < ($1.createdOrder ?? 0, $1.id) }
    return messagesText(outbox, empty: "Outbox is empty.")
  }

  private func messagesText(_ messages: [WorkflowViewerMessage], empty: String) -> String {
    guard !messages.isEmpty else {
      return empty
    }
    return messages.map { message in
      [
        rielaAppMetadataText([
          message.id,
          "State \(message.status.rawValue)",
          "From \(message.fromStepId ?? "-")",
          "To \(message.toStepId ?? (message.deliveryKind == .rootOutput ? "root output" : "-"))",
          message.transitionCondition.map { "When \($0)" } ?? "",
          message.createdAt.map { "Created \(dateFormatter.string(from: $0))" } ?? ""
        ]),
        message.payloadJSON
      ].joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  private func statusColor(_ status: WorkflowStepExecutionStatus) -> NSColor {
    switch status {
    case .running:
      .systemBlue
    case .completed:
      .systemGreen
    case .failed:
      .systemRed
    case .skipped:
      .systemGray
    }
  }
}
#endif
