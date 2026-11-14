#if os(macOS)
import Foundation
import RielaCore
import RielaViewer

extension WorkflowViewerWindowController {
  func selectedSession(in state: WorkflowViewerState) -> WorkflowViewerSessionSummary? {
    guard let selectedSessionId = state.selectedSessionId else {
      return nil
    }
    return state.sessions.first { $0.sessionId == selectedSessionId }
  }

  func workflowOverview(state: WorkflowViewerState) -> String {
    rielaAppMetadataText([
      "Workflow \(state.workflow.workflowId)",
      "Entry \(state.workflow.entryStepId)",
      "Steps \(state.workflow.steps.count)",
      "Session Store \(state.sessionStoreRoot)",
      state.workflow.description.isEmpty ? "" : "Description \(state.workflow.description)"
    ])
  }

  func renderRunLog(
    state: WorkflowViewerState,
    selectedStepId: String?,
    session: WorkflowViewerSessionSummary?
  ) -> [String] {
    var lines = ["Run Log"]
    guard let session else {
      lines.append("No runs recorded for this workflow.")
      lines.append("Searched Session Stores")
      lines.append(contentsOf: state.sessionStoreCandidates.map { "- \($0)" })
      return lines
    }
    lines.append(rielaAppMetadataText([
      "Session \(session.sessionId)",
      "State \(workflowViewerStateText(session.status.rawValue))",
      "Updated \(timelineDateFormatter.string(from: session.updatedAt))"
    ]))
    lines.append("")
    lines.append("Step Timeline")
    lines.append(contentsOf: renderTimeline(state.timeline))
    guard let selectedStepId else {
      return lines
    }
    lines.append("")
    lines.append("Step Messages")
    do {
      let messages = try loader.nodeMessages(
        stepId: selectedStepId,
        sessionId: session.sessionId,
        sessionStoreRoot: state.sessionStoreRoot
      )
      lines.append("")
      lines.append("Inbox")
      lines.append(contentsOf: render(messages.inbox))
      lines.append("")
      lines.append("Outbox")
      lines.append(contentsOf: render(messages.outbox))
    } catch {
      lines.append("")
      lines.append("Messages failed to load: \(error)")
    }
    return lines
  }

  func renderWorkflowStructure(state: WorkflowViewerState) -> [String] {
    var lines = ["Workflow Structure", workflowOverview(state: state), ""]
    lines.append("Steps")
    lines.append(contentsOf: renderStructureNodes(state.nodes))
    let templateFiles = flattenedNodes(state.nodes)
      .flatMap(\.templateFiles)
      .sorted { lhs, rhs in
        if lhs.stepId == rhs.stepId {
          return lhs.relativePath < rhs.relativePath
        }
        return lhs.stepId < rhs.stepId
      }
    lines.append("")
    lines.append("Original Workflow Templates")
    if templateFiles.isEmpty {
      lines.append("(none)")
    } else {
      lines.append(contentsOf: templateFiles.map { templateFile in
        let metadata = rielaAppMetadataText([
          templateFile.relativePath,
          "Step \(templateFile.stepId)",
          "Node \(templateFile.nodeId)",
          "Role \(templateFile.role.label)",
          "Field \(templateFile.fieldPath)",
          "Used by Step \(templateFile.isActiveForStep ? "Yes" : "No")"
        ])
        return "- \(metadata)"
      })
    }
    return lines
  }

  func renderStructureNodes(_ nodes: [WorkflowViewerNode], indent: String = "") -> [String] {
    nodes.flatMap { node in
      let metadata = rielaAppMetadataText([
        node.id,
        "Node \(node.nodeId)",
        "State \(workflowViewerStateText(node.state.rawValue))",
        node.templateFiles.isEmpty ? "" : "Templates \(node.templateFiles.count)"
      ])
      let current = "\(indent)- \(metadata)"
      return [current] + renderStructureNodes(node.children, indent: "\(indent)  ")
    }
  }

  func render(_ messages: [WorkflowViewerMessage]) -> [String] {
    guard !messages.isEmpty else {
      return ["(none)"]
    }
    return messages.map { message in
      let metadata = rielaAppMetadataText([
        message.id,
        "State \(workflowViewerStateText(message.status.rawValue))",
        "From \(message.fromStepId ?? "-")",
        "To \(message.toStepId ?? "-")"
      ])
      return [
        "- \(metadata)",
        "  Payload \(message.payloadPreview)"
      ].joined(separator: "\n")
    }
  }

  func sessionTitle(_ summary: WorkflowViewerSessionSummary) -> String {
    rielaAppMetadataText([
      summary.sessionId,
      workflowViewerStateText(summary.status.rawValue),
      workflowViewerStageText(for: summary.activeStepIds)
    ])
  }

  func workflowViewerStageText(for stepIds: [String]) -> String {
    let stageLabels = stepIds.compactMap(workflowViewerStageLabel)
    if !stageLabels.isEmpty {
      return stageLabels.joined(separator: ", ")
    }
    return stepIds.isEmpty ? "" : "Current Step \(stepIds.joined(separator: ","))"
  }

  private func workflowViewerStageLabel(for stepId: String) -> String? {
    let normalized = stepId.lowercased()
    if normalized.contains("ocr") {
      return "OCR in progress"
    }
    if normalized.contains("translate") || normalized.contains("translation") {
      return "Translation in progress"
    }
    if normalized.contains("ingest") || normalized.contains("note-create") || normalized.contains("create-note") {
      return "Note creation in progress"
    }
    return nil
  }

  func workflowViewerStateText(_ rawValue: String) -> String {
    if rawValue == WorkflowViewerNodeRuntimeState.active.rawValue {
      return "Running"
    }
    return rawValue
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .capitalized
  }

  func renderTimeline(_ entries: [WorkflowViewerTimelineEntry]) -> [String] {
    guard !entries.isEmpty else {
      return ["No step executions recorded for this session."]
    }
    return entries.map { entry in
      let metadata = rielaAppMetadataText([
        entry.stepId,
        "State \(workflowViewerStateText(entry.status.rawValue))",
        "Node \(entry.nodeId)",
        "Attempt \(entry.attempt)",
        "Started \(timelineDateFormatter.string(from: entry.startedAt))",
        "Duration \(timelineDuration(entry.duration))"
      ])
      return [
        "- \(metadata)",
        entry.backend.map { "  Backend \($0.rawValue)" },
        entry.lastBackendEventType.map { "  Last Event \($0)" },
        entry.failureReason.map { "  Failure \($0)" }
      ].compactMap { $0 }.joined(separator: "\n")
    }
  }

  func timelineDuration(_ duration: TimeInterval?) -> String {
    guard let duration else {
      return "running"
    }
    return String(format: "%.2fs", max(0, duration))
  }

  func flattenedNodes(_ nodes: [WorkflowViewerNode]) -> [WorkflowViewerNode] {
    nodes.flatMap { [$0] + flattenedNodes($0.children) }
  }
}
#endif
