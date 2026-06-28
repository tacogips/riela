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
    [
      "id: \(state.workflow.workflowId)",
      "entry: \(state.workflow.entryStepId)",
      "description: \(state.workflow.description.isEmpty ? "-" : state.workflow.description)",
      "steps: \(state.workflow.steps.count)",
      "sessionStore: \(state.sessionStoreRoot)"
    ].joined(separator: "\n")
  }

  func renderRunLog(
    state: WorkflowViewerState,
    selectedStepId: String?,
    session: WorkflowViewerSessionSummary?
  ) -> [String] {
    var lines = ["Run Log"]
    guard let session else {
      lines.append("No persisted sessions found for this workflow.")
      lines.append("Searched:")
      lines.append(contentsOf: state.sessionStoreCandidates.map { "- \($0)" })
      return lines
    }
    lines.append("Session: \(session.sessionId)")
    lines.append("Status: \(session.status.rawValue)")
    lines.append("Updated: \(timelineDateFormatter.string(from: session.updatedAt))")
    lines.append("")
    lines.append("Step Timeline")
    lines.append(contentsOf: renderTimeline(state.timeline))
    guard let selectedStepId else {
      return lines
    }
    lines.append("")
    lines.append("Selected Step Messages")
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
        [
          "- \(templateFile.relativePath)",
          "  step: \(templateFile.stepId)",
          "  node: \(templateFile.nodeId)",
          "  role: \(templateFile.role.label)",
          "  field: \(templateFile.fieldPath)",
          "  active: \(templateFile.isActiveForStep ? "yes" : "no")"
        ].joined(separator: "\n")
      })
    }
    return lines
  }

  func renderStructureNodes(_ nodes: [WorkflowViewerNode], indent: String = "") -> [String] {
    nodes.flatMap { node in
      let templates = node.templateFiles.isEmpty ? "" : " templates: \(node.templateFiles.count)"
      let current = "\(indent)- \(node.id) -> \(node.nodeId) [\(node.state.rawValue)]\(templates)"
      return [current] + renderStructureNodes(node.children, indent: "\(indent)  ")
    }
  }

  func render(_ messages: [WorkflowViewerMessage]) -> [String] {
    guard !messages.isEmpty else {
      return ["(none)"]
    }
    return messages.map { message in
      [
        "- \(message.id) [\(message.status.rawValue)]",
        "  from: \(message.fromStepId ?? "-")",
        "  to: \(message.toStepId ?? "-")",
        "  payload: \(message.payloadPreview)"
      ].joined(separator: "\n")
    }
  }

  func sessionTitle(_ summary: WorkflowViewerSessionSummary) -> String {
    let active = summary.activeStepIds.isEmpty ? "" : " active: \(summary.activeStepIds.joined(separator: ","))"
    return "\(summary.sessionId) - \(summary.status.rawValue)\(active)"
  }

  func renderTimeline(_ entries: [WorkflowViewerTimelineEntry]) -> [String] {
    guard !entries.isEmpty else {
      return ["No step executions recorded for this session."]
    }
    return entries.map { entry in
      [
        "\(timelineMarker(entry.status)) \(entry.stepId) [\(entry.status.rawValue)]",
        "  node: \(entry.nodeId)",
        "  attempt: \(entry.attempt)",
        "  started: \(timelineDateFormatter.string(from: entry.startedAt))",
        "  duration: \(timelineDuration(entry.duration))",
        entry.backend.map { "  backend: \($0.rawValue)" },
        entry.lastBackendEventType.map { "  last event: \($0)" },
        entry.failureReason.map { "  failure: \($0)" }
      ].compactMap { $0 }.joined(separator: "\n")
    }
  }

  func timelineMarker(_ status: WorkflowStepExecutionStatus) -> String {
    switch status {
    case .running:
      "[Running]"
    case .completed:
      "[Done]"
    case .skipped:
      "[Skipped]"
    case .failed:
      "[Failed]"
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
