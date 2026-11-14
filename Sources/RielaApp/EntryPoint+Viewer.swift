#if os(macOS)
import AppKit
import Foundation
import RielaCore

extension RielaApp {
  @objc func openViewer() {
    guard let path = selectedWorkflow?.path else {
      selectWorkflow()
      return
    }
    if viewerWindowController == nil {
      viewerWindowController = WorkflowViewerWindowController()
    }
    viewerWindowController?.show(
      workflowDirectory: path,
      sessionStoreRoot: selectedSessionStoreRoot,
      currentDirectory: selectedWorkingDirectory,
      onSendManagerMessage: { [weak self] workflowId, sessionId, stepId, message in
        self?.sendWorkflowViewerManagerMessage(
          workflowId: workflowId,
          sessionId: sessionId,
          stepId: stepId,
          message: message
        ) ?? "RielaApp is not available"
      },
      assistantProfileName: daemonProfileName,
      assistantSettings: daemonState.assistant,
      onSaveAssistantSettings: { [weak self] settings in
        self?.saveAssistantSettings(settings) ?? "RielaApp is not available"
      },
      onSubmitAssistantMessage: { [weak self] message, workingDirectory in
        self?.submitAssistantMessage(message, workingDirectory: workingDirectory)
      }
    )
  }

  private func sendWorkflowViewerManagerMessage(
    workflowId: String,
    sessionId: String,
    stepId: String,
    message: String
  ) -> String? {
    guard let selectedSessionStoreRoot else {
      return "Session store is unavailable."
    }
    do {
      let runtimeRoot = URL(fileURLWithPath: selectedSessionStoreRoot, isDirectory: true)
        .appendingPathComponent("runtime-records", isDirectory: true)
        .path
      let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
      var snapshot = try store.load(sessionId: sessionId)
      guard snapshot.session.workflowId == workflowId else {
        return "Selected session belongs to \(snapshot.session.workflowId)."
      }
      guard let sourceExecution = snapshot.session.executions.last else {
        return "Selected session has no step execution to attach a manager message to."
      }
      let nextOrder = (snapshot.workflowMessages.map(\.createdOrder).max() ?? 0) + 1
      let communicationId = "graphql-manager-\(sessionId)-\(nextOrder)"
      snapshot.workflowMessages.append(WorkflowMessageRecord(
        communicationId: communicationId,
        workflowExecutionId: sessionId,
        fromStepId: nil,
        toStepId: stepId,
        routingScope: .workflow,
        deliveryKind: .direct,
        sourceStepExecutionId: sourceExecution.executionId,
        payload: [
          "kind": .string("message"),
          "managerMessage": .string(message)
        ],
        lifecycleStatus: .delivered,
        createdOrder: nextOrder,
        createdAt: Date()
      ))
      try store.save(snapshot)
      status = "Sent manager message to \(workflowId)"
      return nil
    } catch {
      return "Failed to send manager message: \(error)"
    }
  }
}
#endif
