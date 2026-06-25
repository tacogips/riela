import XCTest
import RielaMemory
@testable import RielaCore

// This suite keeps related runner state-machine cases together while support fixtures live in a separate file.
// swiftlint:disable:next type_body_length
final class DeterministicWorkflowRunnerTests: XCTestCase {
  func testAdapterFailureRecordsFailedExecutionWithoutMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(store: store, adapter: FailingAdapter())

    await XCTAssertThrowsErrorAsync(try await runner.run(request()))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testCompletionFailureRecordsFailedExecutionWithoutMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output(completionPassed: false, payload: ["status": .string("blocked")]))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(request()))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testInvalidOutputContractRecordsFailedExecutionWithoutMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let node = payload(
      output: NodeOutputContract(
        jsonSchema: [
          "type": .string("object"),
          "required": .array([.string("status")])
        ]
      )
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output(payload: ["other": .string("value")])))

    await XCTAssertThrowsErrorAsync(try await runner.run(request(nodePayload: node)))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testUnsupportedTransitionRecordsFailureBeforeMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = workflow(transitions: [WorkflowStepTransition(toStepId: "child", toWorkflowId: "child-workflow")])
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    await XCTAssertThrowsErrorAsync(try await runner.run(request(workflow: workflow)))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testMultiplePublishableTransitionsFailClosedWithoutMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "left-node", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRegistryRef(id: "right-node", nodeFile: "nodes/right-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(toStepId: "left"),
            WorkflowStepTransition(toStepId: "right")
          ]
        ),
        WorkflowStepRef(id: "left", nodeId: "left-node"),
        WorkflowStepRef(id: "right", nodeId: "right-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "left", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRef(id: "right", nodeFile: "nodes/right-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "left-node": payload(),
        "right-node": payload()
      ]
    )))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: multiple direct transitions are not supported by the Swift TASK-007 sequential runner")
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testMultipleEnvelopeTransitionsFailClosedAfterOutputNormalization() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "left-node", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRegistryRef(id: "right-node", nodeFile: "nodes/right-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(toStepId: "left", label: "left"),
            WorkflowStepTransition(toStepId: "right", label: "right")
          ]
        ),
        WorkflowStepRef(id: "left", nodeId: "left-node"),
        WorkflowStepRef(id: "right", nodeId: "right-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "left", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRef(id: "right", nodeFile: "nodes/right-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: AdapterExecutionOutput(
        provider: "test",
        model: "gpt-5.5",
        promptText: "prompt",
        completionPassed: true,
        when: ["left": false, "right": false],
        payload: [
          "when": .object(["left": .bool(true), "right": .bool(true)]),
          "payload": .object(["status": .string("ok")])
        ]
      ))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "left-node": payload(),
        "right-node": payload()
      ]
    )))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: multiple direct transitions are not supported by the Swift TASK-007 sequential runner")
    XCTAssertNil(session.executions.first?.acceptedOutput)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testNegatedTransitionLabelPublishesWhenFlagIsFalse() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "next-node", nodeFile: "nodes/next-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [WorkflowStepTransition(toStepId: "next", label: "!(needs_revision)")]
        ),
        WorkflowStepRef(id: "next", nodeId: "next-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "next", nodeFile: "nodes/next-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output(when: ["needs_revision": false]))
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "next-node": payload()
      ]
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.nodeExecutions, 2)
    XCTAssertEqual(result.transitions, 1)
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.map(\.toStepId), ["next"])
  }

  func testMultipleExpressionTransitionsFailClosedUsingBranchEvaluator() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "left-node", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRegistryRef(id: "right-node", nodeFile: "nodes/right-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(toStepId: "left", label: "!(left)"),
            WorkflowStepTransition(toStepId: "right", label: "!(right)")
          ]
        ),
        WorkflowStepRef(id: "left", nodeId: "left-node"),
        WorkflowStepRef(id: "right", nodeId: "right-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "left", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRef(id: "right", nodeFile: "nodes/right-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output(when: ["left": false, "right": false]))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "left-node": payload(),
        "right-node": payload()
      ]
    )))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: multiple direct transitions are not supported by the Swift TASK-007 sequential runner")
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testMessageAppendFailureDoesNotFabricateDownstreamMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore(appendFailurePredicate: { _ in "append blocked" })
    let workflow = workflow(transitions: [WorkflowStepTransition(toStepId: "step")])
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    await XCTAssertThrowsErrorAsync(try await runner.run(request(workflow: workflow)))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertNil(session.executions.first?.acceptedOutput)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testTimeoutOptionsPropagateAdapterDeadline() async throws {
    let adapter = DeadlineCapturingAdapter()
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    _ = try await runner.run(request(timeoutMs: 500))

    let maybeDeadline = await adapter.capturedDeadline()
    let deadline = try XCTUnwrap(maybeDeadline)
    XCTAssertLessThanOrEqual(deadline.timeIntervalSinceNow, 0.5)
    XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 0)
  }

  func testAddonOnlyNodePublishesThroughInjectedResolver() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = CapturingAddonResolver(output: output(payload: ["status": .string("addon-ok")]))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: addonWorkflow(),
      variables: ["request": .string("value")]
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.rootOutput, ["status": .string("addon-ok")])
    XCTAssertEqual(result.nodeExecutions, 1)
    let maybeCaptured = await resolver.capturedInput()
    let captured = try XCTUnwrap(maybeCaptured)
    XCTAssertEqual(captured.workflowId, "addon-runner")
    XCTAssertEqual(captured.stepId, "addon-step")
    XCTAssertEqual(captured.nodeId, "addon-node")
    XCTAssertEqual(captured.addon.name, "riela/native-runner")
    XCTAssertEqual(captured.variables["request"], .string("value"))
  }

  func testAddonOnlyNodeProjectsInlineAttachmentDescriptorsBeforeResolver() async throws {
    let resolver = CapturingAddonResolver(output: output(payload: ["status": .string("addon-ok")]))
    let runner = DeterministicWorkflowRunner(addonResolver: resolver)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: addonWorkflow(),
      addonAttachmentDescriptors: [
        "attachmentId": WorkflowAddonAttachmentDescriptor(
          id: "att_123",
          mediaType: "text/plain",
          filename: "note.txt",
          contentText: "hello native"
        )
      ]
    ))

    XCTAssertEqual(result.status, .completed)
    let maybeCaptured = await resolver.capturedInput()
    let captured = try XCTUnwrap(maybeCaptured)
    let attachment = try XCTUnwrap(captured.attachments["attachmentId"])
    XCTAssertEqual(attachment.id, "att_123")
    XCTAssertEqual(attachment.mediaType, "text/plain")
    XCTAssertEqual(attachment.filename, "note.txt")
    XCTAssertEqual(attachment.sizeBytes, "hello native".utf8.count)
    XCTAssertTrue(attachment.sha256.hasPrefix("sha256:"))
    XCTAssertEqual(attachment.contentText, "hello native")
    XCTAssertNil(attachment.contentBase64)
  }

  func testAddonOnlyNodeRejectsHostPathAttachmentDescriptorsBeforeResolver() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = CapturingAddonResolver(output: output(payload: ["status": .string("should-not-run")]))
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: addonWorkflow(),
      addonAttachmentDescriptors: [
        "attachmentId": WorkflowAddonAttachmentDescriptor(
          id: "att_123",
          mediaType: "text/plain",
          filename: "note.txt",
          localPath: "/tmp/secret.txt"
        )
      ]
    )))

    let captured = await resolver.capturedInput()
    XCTAssertNil(captured)
    let maybeSession = await store.loadSessionForTest(id: "addon-runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertTrue(session.executions.first?.failureReason?.contains("native_attachment_metadata_only") == true)
  }

  func testAddonOnlyNodeWithoutResolverRecordsFailure() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(store: store)

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(workflow: addonWorkflow())))

    let maybeSession = await store.loadSessionForTest(id: "addon-runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertTrue(session.executions.first?.failureReason?.contains("missing add-on resolver") == true)
  }

  func testRunRendersHydratedPromptTemplateAndPromptVariantBeforeAdapterExecution() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      description: "fallback {{topic}}",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      prompts: WorkflowPrompts(workerSystemPromptTemplate: "workflow system {{topic}}"),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          description: "step fallback {{topic}}",
          role: .worker,
          promptVariant: "review"
        )
      ],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
    let node = AgentNodePayload(
      id: "node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      systemPromptTemplate: "base system {{topic}}",
      promptTemplate: "base prompt {{topic}}",
      sessionStartPromptTemplate: "base start {{topic}}",
      promptVariants: [
        "review": NodePromptVariant(
          systemPromptTemplate: "variant system {{topic}}",
          promptTemplate: "variant prompt {{topic}} {{nodeId}} {{nodeKind}}",
          sessionStartPromptTemplate: "variant start {{topic}}"
        )
      ],
      variables: ["topic": .string("base")]
    )
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": node],
      variables: ["topic": .string("release")]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(
      input.promptText,
      "variant start release\n\nvariant prompt release step worker"
    )
    XCTAssertEqual(
      input.systemPromptText,
      "workflow system release\n\nvariant system release"
    )
    XCTAssertFalse(input.promptText.contains("fallback"))
    XCTAssertFalse(input.promptText.contains("base prompt"))
    XCTAssertEqual(input.node.promptTemplateFile, nil)
    XCTAssertEqual(input.node.id, "step")
  }

  func testRunPreservesConfiguredPromptTemplateThatRendersEmpty() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      description: "workflow fallback",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          description: "step fallback must not run",
          role: .worker
        )
      ],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
    let node = AgentNodePayload(
      id: "node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      promptTemplate: "{{ missing.path }}"
    )
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": node]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.promptText, "")
    XCTAssertFalse(input.promptText.contains("fallback"))
  }

  func testMaxLoopIterationsBoundsDeterministicRun() async throws {
    let loopingWorkflow = workflow(
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 10),
      transitions: [WorkflowStepTransition(toStepId: "step")]
    )
    let runner = DeterministicWorkflowRunner(adapter: StaticAdapter(output: output()))

    do {
      _ = try await runner.run(request(workflow: loopingWorkflow, maxLoopIterations: 1))
      XCTFail("expected maxStepsExceeded")
    } catch DeterministicWorkflowRunnerError.maxStepsExceeded(let maxSteps) {
      XCTAssertEqual(maxSteps, 2)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testCommandNodePublishesValidStdoutOutputThroughRuntimeStore() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let executor = StaticStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: ["status": .string("ok")]))
    let runner = DeterministicWorkflowRunner(store: store, stdioNodeExecutor: executor)
    let result = try await runner.run(request(nodePayload: commandPayload()))

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.rootOutput, ["status": .string("ok")])
    let capturedInputs = await executor.capturedInputs()
    let capturedInput = try XCTUnwrap(capturedInputs.first)
    XCTAssertEqual(capturedInput.workflowId, "runner")
    XCTAssertEqual(capturedInput.stepId, "step")
    XCTAssertEqual(capturedInput.kind, .command)
    let loadedSession = await store.loadSessionForTest(id: result.session.sessionId)
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.executions.first?.acceptedOutput?.payload, ["status": .string("ok")])
  }

  func testCommandNodeEmptyStdoutCompletesWithoutAcceptedOutput() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      stdioNodeExecutor: StaticStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: nil))
    )
    let result = try await runner.run(request(nodePayload: commandPayload()))

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertNil(result.rootOutput)
    let loadedSession = await store.loadSessionForTest(id: result.session.sessionId)
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.status, .completed)
    XCTAssertEqual(session.executions.first?.status, .completed)
    XCTAssertNil(session.executions.first?.acceptedOutput)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testCommandNodeInvalidStdoutRecordsFailedExecution() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      stdioNodeExecutor: StaticStdioNodeExecutor(error: AdapterExecutionError(.invalidOutput, "stdout invalid JSONL"))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(request(nodePayload: commandPayload())))

    let loadedSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: stdout invalid JSONL")
  }

  func testCommandNodeMultiplePublishableTransitionsFailClosed() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "left-node", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRegistryRef(id: "right-node", nodeFile: "nodes/right-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(toStepId: "left"),
            WorkflowStepTransition(toStepId: "right")
          ]
        ),
        WorkflowStepRef(id: "left", nodeId: "left-node"),
        WorkflowStepRef(id: "right", nodeId: "right-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "left", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRef(id: "right", nodeFile: "nodes/right-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      stdioNodeExecutor: StaticStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: ["status": .string("ok")]))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": commandPayload()]
    )))

    let loadedSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: multiple direct transitions are not supported by the Swift TASK-007 sequential runner")
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testRerunCreatesNewSessionStartingAtRequestedStep() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = twoStepWorkflow()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StepCapturingAdapter(outputsByStep: [
        "step-a": output(payload: ["status": .string("first")]),
        "step-b": output(payload: ["status": .string("second")])
      ])
    )

    let first = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow)
    ))
    XCTAssertEqual(first.status, .completed)
    XCTAssertEqual(first.session.executions.map(\.stepId), ["step-a", "step-b"])
    XCTAssertEqual(first.recovery?.entryMode, .run)
    XCTAssertEqual(first.recovery?.inputReusePolicy, "fresh-input")

    let rerun = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      rerunFromSessionId: first.session.sessionId,
      rerunFromStepId: "step-b"
    ))

    XCTAssertNotEqual(rerun.session.sessionId, first.session.sessionId)
    XCTAssertEqual(rerun.status, .completed)
    XCTAssertEqual(rerun.session.executions.map(\.stepId), ["step-b"])
    XCTAssertEqual(rerun.rootOutput?["status"], .string("second"))
    XCTAssertEqual(rerun.recovery?.entryMode, .rerun)
    XCTAssertEqual(rerun.recovery?.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(rerun.recovery?.sourceStepId, "step-b")
    XCTAssertEqual(rerun.recovery?.sourceStepExecutionId, first.session.executions.last?.executionId)
    XCTAssertEqual(rerun.recovery?.parentSessionId, first.session.sessionId)
    XCTAssertEqual(rerun.recovery?.childSessionIds, [rerun.session.sessionId])

    let terminalResume = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow),
      resumeSessionId: rerun.session.sessionId
    ))

    XCTAssertEqual(terminalResume.session.sessionId, rerun.session.sessionId)
    XCTAssertEqual(terminalResume.recovery?.entryMode, .resume)
    XCTAssertEqual(terminalResume.recovery?.sourceSessionId, rerun.session.sessionId)
    XCTAssertEqual(terminalResume.recovery?.inputReusePolicy, "existing-session")
  }

  func testRerunRejectsUnknownStepWithStepOrientedMessage() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = twoStepWorkflow()
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))
    let first = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: nodePayloads(for: workflow)
    ))

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: nodePayloads(for: workflow),
        rerunFromSessionId: first.session.sessionId,
        rerunFromStepId: "missing-step"
      ))
      XCTFail("expected rerun validation failure")
    } catch let error as DeterministicWorkflowRunnerError {
      guard case let .rerunValidation(message) = error else {
        return XCTFail("expected rerunValidation error")
      }
      XCTAssertEqual(message, "unknown rerun step 'missing-step'")
    }
  }

  func testMemoryGuidanceUsesDeclaredNodeIdWhenStepIdDiffers() async throws {
    let workflow = WorkflowDefinition(
      workflowId: "memory-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "persona-step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "persona-node",
          nodeFile: "nodes/persona.json",
          memories: [
            WorkflowMemoryDeclaration(id: "persona-events", description: "chronological persona events")
          ]
        )
      ],
      steps: [WorkflowStepRef(id: "persona-step", nodeId: "persona-node", role: .worker)],
      nodes: [
        WorkflowNodeRef(
          id: "persona-step",
          nodeFile: "nodes/persona.json",
          role: .worker,
          memories: [
            WorkflowMemoryDeclaration(id: "persona-summary", description: "summarized persona memory")
          ]
        )
      ]
    )
    let adapter = InputCapturingAdapter()
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["persona-node": AgentNodePayload(id: "persona-node", executionBackend: .codexAgent, model: "gpt-5.4-mini")]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertTrue(input.systemPromptText?.contains("persona-events") == true)
    XCTAssertTrue(input.systemPromptText?.contains("persona-summary") == true)
    XCTAssertTrue(input.systemPromptText?.contains("--workflow-id memory-runner") == true)
    XCTAssertTrue(input.systemPromptText?.contains("--node-id persona-node") == true)
    guard case let .object(availableMemories)? = input.mergedVariables["availableMemories"],
      case let .array(nodeMemories)? = availableMemories["node"]
    else {
      return XCTFail("expected availableMemories.node")
    }
    XCTAssertEqual(nodeMemories.count, 2)
  }

  func testRegisteredMemoryMetadataPrefersNodePurposeAndFillsWorkflowDefaults() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-memory-metadata-\(UUID().uuidString)", isDirectory: true)
      .path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let workflow = WorkflowDefinition(
      workflowId: "memory-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      memories: [
        WorkflowMemoryDeclaration(
          id: "persona-memory",
          description: "workflow description",
          purpose: "workflow purpose",
          scope: .crossWorkflow,
          defaultLimit: 12
        )
      ],
      entryStepId: "persona-step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "persona-node",
          nodeFile: "nodes/persona.json",
          memories: [
            WorkflowMemoryDeclaration(id: "persona-memory", purpose: "node-specific purpose")
          ]
        )
      ],
      steps: [WorkflowStepRef(id: "persona-step", nodeId: "persona-node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "persona-step", nodeFile: "nodes/persona.json")]
    )
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: StaticAdapter(output: output()))

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["persona-node": AgentNodePayload(id: "persona-node", executionBackend: .codexAgent, model: "gpt-5.4-mini")],
      memoryRootDirectory: root
    ))

    let metadata = try XCTUnwrap(RielaMemoryStore(rootDirectory: root).metadata(memoryId: "persona-memory"))
    XCTAssertEqual(metadata.description, "workflow description")
    XCTAssertEqual(metadata.purpose, "node-specific purpose")
  }

  func testStepSessionPolicyIsPassedToAdapterInput() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "session-policy-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "verify",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "verify-node", nodeFile: "nodes/verify.json")],
      steps: [
        WorkflowStepRef(
          id: "verify",
          nodeId: "verify-node",
          sessionPolicy: WorkflowStepSessionPolicy(mode: .new)
        )
      ],
      nodes: [WorkflowNodeRef(id: "verify", nodeFile: "nodes/verify.json")]
    )
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "verify-node": AgentNodePayload(
          id: "verify-node",
          executionBackend: .codexAgent,
          model: "gpt-5.5"
        )
      ]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.sessionPolicy?.mode, .new)
    XCTAssertNil(input.sessionPolicy?.inheritFromStepId)
  }

  func testStepSessionPolicyOverridesNodeSessionPolicy() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "session-policy-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "worker",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "worker-node", nodeFile: "nodes/worker.json")],
      steps: [
        WorkflowStepRef(
          id: "worker",
          nodeId: "worker-node",
          sessionPolicy: WorkflowStepSessionPolicy(mode: .new)
        )
      ],
      nodes: [WorkflowNodeRef(id: "worker", nodeFile: "nodes/worker.json")]
    )
    let node = AgentNodePayload(
      id: "worker-node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      sessionPolicy: WorkflowStepSessionPolicy(mode: .reuse, inheritFromStepId: "prior")
    )
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["worker-node": node]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.sessionPolicy?.mode, .new)
    XCTAssertNil(input.sessionPolicy?.inheritFromStepId)
  }

  func testNodeSessionPolicyIsPassedToAdapterInputWhenStepDoesNotOverride() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "session-policy-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "worker",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "worker-node", nodeFile: "nodes/worker.json")],
      steps: [WorkflowStepRef(id: "worker", nodeId: "worker-node")],
      nodes: [WorkflowNodeRef(id: "worker", nodeFile: "nodes/worker.json")]
    )
    let node = AgentNodePayload(
      id: "worker-node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      sessionPolicy: WorkflowStepSessionPolicy(mode: .reuse, inheritFromStepId: "prior")
    )
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["worker-node": node]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.sessionPolicy?.mode, .reuse)
    XCTAssertEqual(input.sessionPolicy?.inheritFromStepId, "prior")
  }

  private func request(
    workflow: WorkflowDefinition? = nil,
    nodePayload: AgentNodePayload? = nil,
    maxLoopIterations: Int? = nil,
    timeoutMs: Int? = nil
  ) -> DeterministicWorkflowRunRequest {
    let resolvedWorkflow = workflow ?? self.workflow()
    return DeterministicWorkflowRunRequest(
      workflow: resolvedWorkflow,
      nodePayloads: ["node": nodePayload ?? payload()],
      maxLoopIterations: maxLoopIterations,
      timeoutMs: timeoutMs
    )
  }

  private func workflow(
    defaults: WorkflowDefaults = WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    transitions: [WorkflowStepTransition]? = nil
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner",
      defaults: defaults,
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", transitions: transitions)],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
  }

  private func twoStepWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "rerun-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step-a",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node-a", nodeFile: "nodes/a.json"),
        WorkflowNodeRegistryRef(id: "node-b", nodeFile: "nodes/b.json")
      ],
      steps: [
        WorkflowStepRef(id: "step-a", nodeId: "node-a", transitions: [WorkflowStepTransition(toStepId: "step-b")]),
        WorkflowStepRef(id: "step-b", nodeId: "node-b")
      ],
      nodes: [
        WorkflowNodeRef(id: "step-a", nodeFile: "nodes/a.json"),
        WorkflowNodeRef(id: "step-b", nodeFile: "nodes/b.json")
      ]
    )
  }

  private func nodePayloads(for workflow: WorkflowDefinition) -> [String: AgentNodePayload] {
    Dictionary(uniqueKeysWithValues: workflow.nodeRegistry.map { ref in
      (ref.id, AgentNodePayload(id: ref.id, executionBackend: .codexAgent, model: "gpt-5.5"))
    })
  }

  private func addonWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "addon-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "addon-step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "addon-node",
          addon: WorkflowNodeAddonRef(name: "riela/native-runner", version: "1.0.0")
        )
      ],
      steps: [WorkflowStepRef(id: "addon-step", nodeId: "addon-node")],
      nodes: [
        WorkflowNodeRef(
          id: "addon-node",
          addon: WorkflowNodeAddonRef(name: "riela/native-runner", version: "1.0.0")
        )
      ]
    )
  }

  private func payload(output: NodeOutputContract? = nil) -> AgentNodePayload {
    AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5", output: output)
  }

  private func commandPayload(output: NodeOutputContract? = nil) -> AgentNodePayload {
    AgentNodePayload(
      id: "node",
      nodeType: .command,
      model: "",
      command: WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c", "true"]),
      output: output
    )
  }

  private func output(
    completionPassed: Bool = true,
    payload: JSONObject = ["status": .string("ok")],
    when: [String: Bool] = ["always": true]
  ) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: completionPassed,
      when: when,
      payload: payload
    )
  }
}
