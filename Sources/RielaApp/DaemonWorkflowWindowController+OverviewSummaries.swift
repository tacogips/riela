#if os(macOS)
import AppKit

extension DaemonWorkflowWindowController {
  func updateOverviewSummaries() {
    let sourceCount = workflowSources.count
    sourcesSummaryLabel.stringValue = sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
    let assistance = state.assistant.normalizedAssistance
    assistantSummaryLabel.stringValue = assistance.isEmpty
      ? "No assistance configured"
      : "\(assistance.count) characters configured"
    let profileCount = profileNames.count
    profilesSummaryLabel.stringValue = profileCount == 1 ? "1 profile" : "\(profileCount) profiles"
  }
}
#endif
