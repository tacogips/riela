# wh-12: Task-handover GraphQL contracts and document executor

```json
{
  "planId": "wh-12-graphql-contracts",
  "planPath": "impl-plans/active/wh-12-graphql-contracts.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaGraphQL/TaskHandoverGraphQL.swift",
    "Tests/RielaGraphQLTests/TaskHandoverGraphQLTests.swift",
    "impl-plans/progress/wh-12-graphql-contracts.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-12-graphql-contracts.md"
}
```

## Intent and context

This plan adds the first P5 task fields that a remote successor needs (design §10.2, §12, §14, §21 R8 and R16).
`RielaGraphQL` depends on `RielaCore` only, so this file defines DTOs, a provider protocol, the document executor
and the SDL block. The implementation over `WorkStore` is wh-16. Follow the routine surface exactly
(`Sources/RielaGraphQL/RoutineGraphQL.swift`: DTOs, `RoutineGraphQLProviding`, `RoutineGraphQLDocumentExecutor(provider:next:)`,
the `routineGraphQLSchemaTypes` SDL string at `:423`).

Non-goals: registering root fields in `GraphQLSchemaGenerator.rootFields`, adding the SDL block to
`handWrittenSchemaBlocks`, catalog rows and SDL regeneration (all wh-20); auth (wh-16 wires the wrapper); the provider (wh-16).

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-12-graphql-contracts/`,
writePaths only, arm64 logs, no git state changes, own progress log).

## Deliverables — pinned (wh-16 implements, wh-18 calls, wh-20 registers)

Root fields (the operation names are exact):

```graphql
type Query {
  taskHandover(taskId: String!, handoverId: String): TaskHandoverPayload!
  tasksAwaitingHandover(traits: [String!]): TasksAwaitingHandoverPayload!
}
type Mutation {
  requestTaskHandover(input: RequestTaskHandoverInput!): TaskHandoverMutationPayload!
  answerTask(input: AnswerTaskInput!): TaskHandoverMutationPayload!
  takeoverTask(input: TakeoverTaskInput!): TakeoverTaskPayload!
  heartbeatAttempt(attemptId: String!, token: String!): LeaseStatePayload!
  reportAttempt(input: ReportAttemptInput!): ReportAttemptPayload!
}
```

DTOs (Codable Swift structs, `GraphQL…` prefix as in the routine file; every payload also has `errors: [TaskHandoverGraphQLError]`):
- `GraphQLHandoverPacket {handoverId, taskId, digest, reasonKind, resumeStepId, brief, packet: JSONObject}`. `packet` is the
  canonical packet object, and wh-18 re-verifies the digest with `HandoverSinkVerification`-equivalent logic.
- `GraphQLTaskHandoverSummary {taskId, handoverId, reasonKind, requiredTraits: [String], needsAnswer: Bool, questionText: String?, createdAt: String}`.
- `GraphQLRequestTaskHandoverInput {taskId, reason, immediate: Bool?, target: String?, sinks: [String]?}`.
- `GraphQLAnswerTaskInput {taskId, questionId, answer: JSONObject, principal: String?}`.
- `GraphQLTakeoverTaskInput {taskId, handoverId, hostId, traits: [String], backend: String?, model: String?}`.
- `GraphQLTakeoverTaskPayload {attemptId, sessionId, fence: Int, expiresAt: String, heartbeatToken: String, heartbeatMs: Int, packet: GraphQLHandoverPacket?}`.
- `GraphQLLeaseStatePayload {attemptId, fence: Int, expiresAt: String?, fenced: Bool}`.
- `GraphQLReportAttemptInput {attemptId, token, snapshot: JSONObject /* WorkflowRuntimePersistenceSnapshot */, deliverables: [JSONObject]}`.
- `GraphQLReportAttemptPayload {attemptId, taskState: String, decisionKind: String?, handoverId: String?}`.
- `GraphQLTaskHandoverMutationPayload {taskId, taskState: String, decisionKind: String?, requestId: String?}`.

```swift
public protocol TaskHandoverGraphQLProviding: Sendable {
  func taskHandover(taskId: String, handoverId: String?, context: GraphQLDocumentRequest) async throws -> GraphQLHandoverPacket?
  func tasksAwaitingHandover(traits: [String]?, context: GraphQLDocumentRequest) async throws -> [GraphQLTaskHandoverSummary]
  func requestTaskHandover(_ input: GraphQLRequestTaskHandoverInput, context: GraphQLDocumentRequest) async throws -> GraphQLTaskHandoverMutationPayload
  func answerTask(_ input: GraphQLAnswerTaskInput, context: GraphQLDocumentRequest) async throws -> GraphQLTaskHandoverMutationPayload
  func takeoverTask(_ input: GraphQLTakeoverTaskInput, context: GraphQLDocumentRequest) async throws -> GraphQLTakeoverTaskPayload
  func heartbeatAttempt(attemptId: String, token: String, context: GraphQLDocumentRequest) async throws -> GraphQLLeaseStatePayload
  func reportAttempt(_ input: GraphQLReportAttemptInput, context: GraphQLDocumentRequest) async throws -> GraphQLReportAttemptPayload
}
public struct TaskHandoverGraphQLDocumentExecutor: GraphQLDocumentExecuting { public init(provider: (any TaskHandoverGraphQLProviding)?, next: (any GraphQLDocumentExecuting)? = nil) }
public let taskHandoverGraphQLSchemaTypes: String   // the SDL for every input/payload type above
```

- The executor handles exactly these seven root field names, parses variables with the same helpers the routine executor uses,
  and returns `handled: false` for other documents (it delegates to `next`). A provider error becomes a payload `errors` entry
  with a code (`not_found`, `invalid_input`, `conflict`, `unauthorized`, `internal`), matching the routine error style.
- `reportAttempt` refuses an input document above 4 MiB (measured as UTF-8 bytes of the variables' `input`) with
  `invalid_input` before calling the provider.

## Tests (`TaskHandoverGraphQLTests`, fake provider)

- each of the seven operations routes to the provider with decoded arguments and encodes the payload
- an unrelated document → `handled == false`, delegated to `next`
- provider throws not found → an `errors` entry with its code; `reportAttempt` with a 5 MiB snapshot → invalid_input and the provider is not called
- `taskHandoverGraphQLSchemaTypes` parses with the repository's SDL parser, if one is used for the routine block
  (see `SingleParserTests`); otherwise assert that every type name above is present

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-12-graphql-contracts/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-12-graphql-contracts/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLTests|RoutineGraphQLTests" > tmp/work-handover/wh-12-graphql-contracts/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-12-graphql-contracts/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count.

## Done criteria

- [x] The DTOs, protocol, executor and SDL block match the pinned names; the tests pass; the progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; implemented in `d043cbad` (waves 1-2), acceptance recorded in `7182232d`; SDL registration finished in wh-20. Evidence: `impl-plans/progress/wh-12-graphql-contracts.md`. Archived to `impl-plans/completed/`.
