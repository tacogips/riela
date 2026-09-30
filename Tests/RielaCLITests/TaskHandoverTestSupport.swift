import Foundation
import RielaCore
import RielaWork
@testable import RielaCLI

struct TaskHandoverTestHostResolver: HostCapabilityResolving {
  var traits: [HostTrait] = []

  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    [HostCapabilitySnapshot(
      hostId: "local", capacity: 1, backends: [], refreshedAt: Date(), traits: traits
    )]
  }
}

extension TaskExampleHarness {
  func handoverEnvelopeBundle(workflowId: String) -> ResolvedWorkflowBundle {
    let question: JSONObject = ["id": .string("q1"), "text": .string("Choose"), "options": .array([])]
    let addon = WorkflowNodeAddonRef(
      name: "riela/handover-request", version: "1", config: [
        "reason": .string("userInputRequired"),
        "question": .object(question),
        "progressNote": .string("Waiting for the answer"),
        "resumeStepId": .string("resume")
      ]
    )
    let workflow = WorkflowDefinition(
      workflowId: workflowId,
      defaults: .init(nodeTimeoutMs: 2_000, maxLoopIterations: 1),
      entryStepId: "prelude",
      nodeRegistry: [
        .init(id: "prelude", nodeFile: "prelude.json"),
        .init(id: "request", addon: addon),
        .init(id: "resume", nodeFile: "resume.json")
      ],
      steps: [
        .init(id: "prelude", nodeId: "prelude", transitions: [.init(toStepId: "request")]),
        .init(id: "request", nodeId: "request", transitions: [.init(toStepId: "resume")]),
        .init(id: "resume", nodeId: "resume")
      ],
      nodes: [
        .init(id: "prelude", nodeFile: "prelude.json"),
        .init(id: "request", addon: addon),
        .init(id: "resume", nodeFile: "resume.json")
      ]
    )
    return ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["prelude": .init(
        id: "prelude", nodeType: .command, model: "",
        command: .init(executable: "/bin/echo", arguments: ["{\"ready\":true}"])
      ), "resume": .init(
        id: "resume", nodeType: .command, model: "",
        command: .init(executable: "/usr/bin/true", arguments: [])
      )],
      sourceScope: .project, workflowDirectory: repository.path
    )
  }
}
