import XCTest
@testable import RielaCore

final class WorkflowInputFilterRunnerTests: XCTestCase {
  func testTelegramInputFilterSkipsNonMatchingNodeAndContinues() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = InputFilterExecutedStepCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "telegram-filtered",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "yui",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "yui",
          nodeFile: "nodes/yui.json",
          inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@yui')")]
        ),
        WorkflowNodeRegistryRef(
          id: "mika",
          nodeFile: "nodes/mika.json",
          inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@mika')")]
        )
      ],
      steps: [
        WorkflowStepRef(id: "yui", nodeId: "yui", transitions: [WorkflowStepTransition(toStepId: "mika")]),
        WorkflowStepRef(id: "mika", nodeId: "mika")
      ],
      nodes: [
        WorkflowNodeRef(id: "yui", nodeFile: "nodes/yui.json"),
        WorkflowNodeRef(id: "mika", nodeFile: "nodes/mika.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "yui": inputFilterPayload(),
        "mika": inputFilterPayload()
      ],
      variables: inputFilterTelegramVariables(text: "hello @mika")
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.transitions, 1)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["yui", "mika"])
    XCTAssertEqual(result.session.executions.map(\.status), [.skipped, .completed])
    let executedSteps = await adapter.executedSteps()
    XCTAssertEqual(executedSteps, ["mika"])
  }

  func testTelegramInputFilterSupportsOrConditions() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = InputFilterExecutedStepCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "telegram-filtered",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "mika",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "mika",
          nodeFile: "nodes/mika.json",
          inputFilters: [
            WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@yui')"),
            WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@mika')")
          ]
        )
      ],
      steps: [WorkflowStepRef(id: "mika", nodeId: "mika")],
      nodes: [WorkflowNodeRef(id: "mika", nodeFile: "nodes/mika.json")]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["mika": inputFilterPayload()],
      variables: inputFilterTelegramVariables(text: "hello @mika")
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.status), [.completed])
    let executedSteps = await adapter.executedSteps()
    XCTAssertEqual(executedSteps, ["mika"])
  }

  func testTelegramInputFilterReadsEventMessageText() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = InputFilterExecutedStepCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "telegram-filtered",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "mika",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "mika",
          nodeFile: "nodes/mika.json",
          inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('mika')")]
        )
      ],
      steps: [WorkflowStepRef(id: "mika", nodeId: "mika")],
      nodes: [WorkflowNodeRef(id: "mika", nodeFile: "nodes/mika.json")]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["mika": inputFilterPayload()],
      variables: [
        "event": .object([
          "provider": .string("telegram"),
          "message": .object(["text": .string("mika hello")])
        ])
      ]
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.status), [.completed])
    let executedSteps = await adapter.executedSteps()
    XCTAssertEqual(executedSteps, ["mika"])
  }

  func testTelegramInputFilterEvaluationErrorSkipsWithoutFailingWorkflow() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = InputFilterExecutedStepCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "telegram-filtered",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "yui",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "yui",
          nodeFile: "nodes/yui.json",
          inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes(")]
        )
      ],
      steps: [WorkflowStepRef(id: "yui", nodeId: "yui")],
      nodes: [WorkflowNodeRef(id: "yui", nodeFile: "nodes/yui.json")]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["yui": inputFilterPayload()],
      variables: inputFilterTelegramVariables(text: "hello @yui")
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.status), [.skipped])
    let executedSteps = await adapter.executedSteps()
    XCTAssertEqual(executedSteps, [])
  }

  func testInvalidJavaScriptReportsParseIssue() {
    let decision = WorkflowInputFilterEvaluator().evaluate(
      filters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes(")],
      variables: inputFilterTelegramVariables(text: "hello @yui"),
      stepId: "yui",
      nodeId: "yui"
    )

    XCTAssertFalse(decision.shouldRun)
    XCTAssertEqual(decision.issues.map(\.code), [.parseError])
  }

  func testTelegramInputFilterReadsCanonicalEventPayload() {
    let decision = WorkflowInputFilterEvaluator().evaluate(
      filters: [
        WorkflowInputFilter(
          kind: .telegram,
          expression: "telegram.message.text.includes('@yui') && telegram.message.attachmentText === 'ocr text'"
        )
      ],
      variables: [
        "workflowInput": .object([:]),
        "event": .object([
          "sourceId": .string("telegram-live"),
          "eventId": .string("42"),
          "provider": .string("telegram"),
          "eventType": .string("chat.message"),
          "input": .object([
            "event_source_type": .string("telegram-gateway"),
            "payload": .object([
              "text": .string("@yui hello"),
              "provider": .string("telegram"),
              "actor": .object(["id": .string("200")]),
              "conversation": .object(["id": .string("100"), "threadId": .string("topic-a")]),
              "attachments": .array([.object(["kind": .string("photo")])]),
              "imagePaths": .array([.string("/tmp/image.png")]),
              "attachmentText": .string("ocr text")
            ])
          ])
        ])
      ],
      stepId: "yui",
      nodeId: "yui"
    )

    XCTAssertTrue(decision.shouldRun)
    XCTAssertEqual(decision.matchedFilterIndex, 0)
    XCTAssertEqual(decision.issues.map(\.code), [])
  }

  func testMentionResponderBuiltinAllowsOtherBotMentionAndBlocksSelf() {
    let filter = WorkflowInputFilter(
      kind: .telegram,
      builtin: .mentionResponder,
      config: [
        "aliases": .array([.string("rina"), .string("@rinacursor0529bot")]),
        "selfUsernames": .array([.string("rinacursor0529bot")])
      ]
    )
    let evaluator = WorkflowInputFilterEvaluator()

    let otherBotDecision = evaluator.evaluate(
      filters: [filter],
      variables: inputFilterTelegramVariables(
        text: "@rinacursor0529bot ここ見て",
        actorUsername: "mikatrend0529bot",
        actorIsBot: true
      ),
      stepId: "rina",
      nodeId: "rina"
    )
    let selfDecision = evaluator.evaluate(
      filters: [filter],
      variables: inputFilterTelegramVariables(
        text: "@rinacursor0529bot echo",
        actorUsername: "rinacursor0529bot",
        actorIsBot: true
      ),
      stepId: "rina",
      nodeId: "rina"
    )

    XCTAssertTrue(otherBotDecision.shouldRun)
    XCTAssertFalse(selfDecision.shouldRun)
  }

  func testMentionResponderBuiltinSuppressesPlainAliasWhenAnotherBotIsAddressed() {
    let filter = WorkflowInputFilter(
      kind: .telegram,
      builtin: .mentionResponder,
      config: [
        "aliases": .array([.string("mika"), .string("@mikatrend0529bot")]),
        "selfUsernames": .array([.string("mikatrend0529bot")]),
        "suppressedByAliases": .array([.string("@rinacursor0529bot")])
      ]
    )
    let evaluator = WorkflowInputFilterEvaluator()

    let addressedToRina = evaluator.evaluate(
      filters: [filter],
      variables: inputFilterTelegramVariables(
        text: "@rinacursor0529bot What image did I just show Mika?"
      ),
      stepId: "mika",
      nodeId: "mika"
    )
    let addressedToMikaAboutRina = evaluator.evaluate(
      filters: [filter],
      variables: inputFilterTelegramVariables(
        text: "@mikatrend0529bot What did Rina say?"
      ),
      stepId: "mika",
      nodeId: "mika"
    )

    XCTAssertFalse(addressedToRina.shouldRun)
    XCTAssertTrue(addressedToMikaAboutRina.shouldRun)
  }

  func testMentionResponderBuiltinDefaultResponderSkipsUnaddressedBotMessages() {
    let filter = WorkflowInputFilter(
      kind: .telegram,
      builtin: .mentionResponder,
      config: [
        "aliases": .array([.string("yui"), .string("@yuicodexf0529bot")]),
        "selfUsernames": .array([.string("yuicodexf0529bot")]),
        "defaultResponder": .bool(true),
        "defaultSuppressedByAliases": .array([
          .string("mika"),
          .string("@mikatrend0529bot"),
          .string("rina"),
          .string("@rinacursor0529bot")
        ])
      ]
    )
    let evaluator = WorkflowInputFilterEvaluator()

    let userDefault = evaluator.evaluate(
      filters: [filter],
      variables: inputFilterTelegramVariables(text: "誰かいる?"),
      stepId: "yui",
      nodeId: "yui"
    )
    let botDefault = evaluator.evaluate(
      filters: [filter],
      variables: inputFilterTelegramVariables(text: "誰かいる?", actorUsername: "mikatrend0529bot", actorIsBot: true),
      stepId: "yui",
      nodeId: "yui"
    )
    let botMention = evaluator.evaluate(
      filters: [filter],
      variables: inputFilterTelegramVariables(text: "@yuicodexf0529bot ここお願い", actorUsername: "mikatrend0529bot", actorIsBot: true),
      stepId: "yui",
      nodeId: "yui"
    )

    XCTAssertTrue(userDefault.shouldRun)
    XCTAssertFalse(botDefault.shouldRun)
    XCTAssertTrue(botMention.shouldRun)
  }

  func testTelegramInputFilterSkipAwareTransitionUsesSkipPayload() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = InputFilterExecutedStepCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "telegram-filtered",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "yui",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "yui",
          nodeFile: "nodes/yui.json",
          inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@yui')")]
        ),
        WorkflowNodeRegistryRef(id: "skipped", nodeFile: "nodes/skipped.json"),
        WorkflowNodeRegistryRef(id: "matched", nodeFile: "nodes/matched.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "yui",
          nodeId: "yui",
          transitions: [
            WorkflowStepTransition(toStepId: "matched", label: "ready"),
            WorkflowStepTransition(toStepId: "skipped", label: "input_filter_skipped")
          ]
        ),
        WorkflowStepRef(id: "skipped", nodeId: "skipped"),
        WorkflowStepRef(id: "matched", nodeId: "matched")
      ],
      nodes: [
        WorkflowNodeRef(id: "yui", nodeFile: "nodes/yui.json"),
        WorkflowNodeRef(id: "skipped", nodeFile: "nodes/skipped.json"),
        WorkflowNodeRef(id: "matched", nodeFile: "nodes/matched.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "yui": inputFilterPayload(),
        "skipped": inputFilterPayload(),
        "matched": inputFilterPayload()
      ],
      variables: inputFilterTelegramVariables(text: "hello @mika")
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["yui", "skipped"])
    XCTAssertEqual(result.session.executions.map(\.status), [.skipped, .completed])
    let executedSteps = await adapter.executedSteps()
    XCTAssertEqual(executedSteps, ["skipped"])
  }

  func testSkippedInputFilterPublishesOnlyFirstMatchingTransition() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = InputFilterExecutedStepCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "telegram-filtered",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "yui",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "yui",
          nodeFile: "nodes/yui.json",
          inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@yui')")]
        ),
        WorkflowNodeRegistryRef(id: "default", nodeFile: "nodes/default.json"),
        WorkflowNodeRegistryRef(id: "skip", nodeFile: "nodes/skip.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "yui",
          nodeId: "yui",
          transitions: [
            WorkflowStepTransition(toStepId: "default"),
            WorkflowStepTransition(toStepId: "skip", label: "input_filter_skipped")
          ]
        ),
        WorkflowStepRef(id: "default", nodeId: "default"),
        WorkflowStepRef(id: "skip", nodeId: "skip")
      ],
      nodes: [
        WorkflowNodeRef(id: "yui", nodeFile: "nodes/yui.json"),
        WorkflowNodeRef(id: "default", nodeFile: "nodes/default.json"),
        WorkflowNodeRef(id: "skip", nodeFile: "nodes/skip.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "yui": inputFilterPayload(),
        "default": inputFilterPayload(),
        "skip": inputFilterPayload()
      ],
      variables: inputFilterTelegramVariables(text: "hello @mika")
    ))

    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.map(\.toStepId), ["default"])
    XCTAssertEqual(result.session.executions.map(\.stepId), ["yui", "default"])
    let executedSteps = await adapter.executedSteps()
    XCTAssertEqual(executedSteps, ["default"])
  }

  func testSkippedInputFilterWithNoMatchingTransitionCompletesWithoutRootOutput() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "telegram-filtered",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "yui",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "yui",
          nodeFile: "nodes/yui.json",
          inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@yui')")]
        ),
        WorkflowNodeRegistryRef(id: "ready", nodeFile: "nodes/ready.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "yui",
          nodeId: "yui",
          transitions: [WorkflowStepTransition(toStepId: "ready", label: "ready")]
        ),
        WorkflowStepRef(id: "ready", nodeId: "ready")
      ],
      nodes: [
        WorkflowNodeRef(id: "yui", nodeFile: "nodes/yui.json"),
        WorkflowNodeRef(id: "ready", nodeFile: "nodes/ready.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: InputFilterExecutedStepCapturingAdapter(),
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "yui": inputFilterPayload(),
        "ready": inputFilterPayload()
      ],
      variables: inputFilterTelegramVariables(text: "hello @mika")
    ))

    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(result.status, .completed)
    XCTAssertNil(result.rootOutput)
    XCTAssertEqual(result.session.executions.map(\.status), [.skipped])
    XCTAssertEqual(messages, [])
  }

  func testSkippedInputFilterMarksExecutionFailedWhenTransitionAppendFails() async throws {
    let store = InMemoryWorkflowRuntimeStore(appendFailurePredicate: { _ in "append blocked" })
    let workflow = WorkflowDefinition(
      workflowId: "telegram-filtered",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "yui",
      nodeRegistry: [
        WorkflowNodeRegistryRef(
          id: "yui",
          nodeFile: "nodes/yui.json",
          inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@yui')")]
        ),
        WorkflowNodeRegistryRef(id: "next", nodeFile: "nodes/next.json")
      ],
      steps: [
        WorkflowStepRef(id: "yui", nodeId: "yui", transitions: [WorkflowStepTransition(toStepId: "next")]),
        WorkflowStepRef(id: "next", nodeId: "next")
      ],
      nodes: [
        WorkflowNodeRef(id: "yui", nodeFile: "nodes/yui.json"),
        WorkflowNodeRef(id: "next", nodeFile: "nodes/next.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: InputFilterExecutedStepCapturingAdapter(),
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: [
          "yui": inputFilterPayload(),
          "next": inputFilterPayload()
        ],
        variables: inputFilterTelegramVariables(text: "hello @mika")
      ))
      XCTFail("expected append failure")
    } catch WorkflowRuntimeStoreError.messageAppendRejected(let reason) {
      XCTAssertEqual(reason, "append blocked")
    }

    let latestSession = await store.latestSession(workflowId: "telegram-filtered")
    let session = try XCTUnwrap(latestSession)
    let execution = try XCTUnwrap(session.executions.first)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(execution.status, .failed)
    XCTAssertNil(execution.acceptedOutput)
    XCTAssertEqual(execution.failureReason, "messageAppendRejected(\"append blocked\")")
  }

  func testSkippedInputFilterRejectsUnsupportedTransitionShapes() async throws {
    let unsupportedTransitions: [(WorkflowStepTransition, String)] = [
      (
        WorkflowStepTransition(toStepId: "child-start", toWorkflowId: "child-workflow"),
        "cross-workflow transitions are not supported by the Swift TASK-005 in-memory publisher"
      ),
      (
        WorkflowStepTransition(toStepId: "next", resumeStepId: "resume"),
        "resume-step transitions are not supported by the Swift TASK-005 in-memory publisher"
      ),
      (
        WorkflowStepTransition(
          toStepId: "fanout-start",
          fanout: WorkflowStepFanout(groupId: "group", itemsFrom: "/items", joinStepId: "join")
        ),
        "fanout transitions are not supported by the Swift TASK-005 in-memory publisher"
      )
    ]

    for (transition, reason) in unsupportedTransitions {
      let store = InMemoryWorkflowRuntimeStore()
      let workflow = WorkflowDefinition(
        workflowId: "telegram-filtered",
        defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
        entryStepId: "yui",
        nodeRegistry: [
          WorkflowNodeRegistryRef(
            id: "yui",
            nodeFile: "nodes/yui.json",
            inputFilters: [WorkflowInputFilter(kind: .telegram, expression: "telegram.message.text.includes('@yui')")]
          ),
          WorkflowNodeRegistryRef(id: "next", nodeFile: "nodes/next.json"),
          WorkflowNodeRegistryRef(id: "resume", nodeFile: "nodes/resume.json"),
          WorkflowNodeRegistryRef(id: "fanout-start", nodeFile: "nodes/fanout-start.json"),
          WorkflowNodeRegistryRef(id: "join", nodeFile: "nodes/join.json")
        ],
        steps: [
          WorkflowStepRef(id: "yui", nodeId: "yui", transitions: [transition]),
          WorkflowStepRef(id: "next", nodeId: "next"),
          WorkflowStepRef(id: "resume", nodeId: "resume"),
          WorkflowStepRef(id: "fanout-start", nodeId: "fanout-start"),
          WorkflowStepRef(id: "join", nodeId: "join")
        ],
        nodes: [
          WorkflowNodeRef(id: "yui", nodeFile: "nodes/yui.json"),
          WorkflowNodeRef(id: "next", nodeFile: "nodes/next.json"),
          WorkflowNodeRef(id: "resume", nodeFile: "nodes/resume.json"),
          WorkflowNodeRef(id: "fanout-start", nodeFile: "nodes/fanout-start.json"),
          WorkflowNodeRef(id: "join", nodeFile: "nodes/join.json")
        ]
      )
      let runner = DeterministicWorkflowRunner(
        store: store,
        adapter: InputFilterExecutedStepCapturingAdapter(),
        inputFilterLogger: NoopWorkflowInputFilterLogger()
      )

      do {
        _ = try await runner.run(DeterministicWorkflowRunRequest(
          workflow: workflow,
          nodePayloads: ["yui": inputFilterPayload()],
          variables: inputFilterTelegramVariables(text: "hello @mika")
        ))
        XCTFail("expected unsupported transition failure")
      } catch WorkflowPublicationError.unsupportedTransition(let actualReason) {
        XCTAssertEqual(actualReason, reason)
      }

      let latestSession = await store.latestSession(workflowId: "telegram-filtered")
      let session = try XCTUnwrap(latestSession)
      let execution = try XCTUnwrap(session.executions.first)
      let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
      XCTAssertEqual(session.status, .failed)
      XCTAssertEqual(execution.status, .failed)
      XCTAssertNil(execution.acceptedOutput)
      XCTAssertEqual(execution.failureReason, reason)
      XCTAssertEqual(messages, [])
    }
  }
}

private actor InputFilterExecutedStepCapturingAdapter: NodeAdapter {
  private var steps: [String] = []

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    steps.append(input.node.id)
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }

  func executedSteps() -> [String] {
    steps
  }
}

private func inputFilterPayload(output: NodeOutputContract? = nil) -> AgentNodePayload {
  AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5", output: output)
}

private func inputFilterTelegramVariables(
  text: String,
  actorUsername: String? = nil,
  actorIsBot: Bool = false
) -> JSONObject {
  [
    "workflowInput": .object([
      "text": .string(text),
      "provider": .string("telegram")
    ]),
    "event": .object([
      "sourceId": .string("telegram-live"),
      "eventId": .string("42"),
      "provider": .string("telegram"),
      "eventType": .string("chat.message"),
      "input": .object([
        "text": .string(text),
        "provider": .string("telegram")
      ]),
      "conversation": .object([
        "id": .string("100"),
        "threadId": .string("topic-a")
      ]),
      "actor": .object([
        "id": .string("200"),
        "displayName": .string("Test User"),
        "username": actorUsername.map(JSONValue.string) ?? .null,
        "isBot": .bool(actorIsBot)
      ])
    ])
  ]
}
