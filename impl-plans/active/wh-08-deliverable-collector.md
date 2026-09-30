# wh-08: Document and local-only deliverable collection

```json
{
  "planId": "wh-08-deliverable-collector",
  "planPath": "impl-plans/active/wh-08-deliverable-collector.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaWork/DeliverableCollector.swift",
    "Tests/RielaWorkTests/DeliverableCollectorTests.swift",
    "impl-plans/progress/wh-08-deliverable-collector.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-08-deliverable-collector.md"
}
```

## Intent and context

The packet must name the documents an attempt wrote (kaiba notes, ids declared through `output.deliverables`, for example the task
ids from a monja command node) and must list the cwd-local state that cannot move (riela memory and KV). Design §9.2, §9.3 and §21 R15.
These are references, never copies. Types: `DeliverableRef`, `DocumentDeliverable`, `LocalOnlyDeliverable` (wh-01) and
`NodeOutputContract.deliverables: WorkflowDeliverableProjection?` (wh-01; the node payload `output` is
`WorkflowModel.swift:796`).

Non-goals: repository deliverables (wh-07/wh-14), builtin mappings for gateway add-ons other than those
declared through `output.deliverables`, and any network calls.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-08-deliverable-collector/`,
writePaths only, arm64 logs, no git state changes, own progress log).

## Deliverables — pinned API

```swift
public struct DeliverableCollector: Sendable {
  public init(workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload])
  public func collect(snapshot: WorkflowRuntimePersistenceSnapshot) -> [DeliverableRef]
}
```

Rules (only accepted executions: `status == .completed && acceptedOutput != nil`). The step → node
mapping uses `workflow.steps[].nodeId`. The add-on comes from the registry node (`workflow.nodes[]`, `WorkflowNodeRef.addon`):
1. The add-on name has the prefix `kaiba/`: ids are payload keys `noteId` and `notebookId` (string, or array of strings).
   The instance is `addon.config["kaibaInstanceId"]` as a string, else nil. The store is `"kaiba"`.
2. `nodePayloads[nodeId]?.output?.deliverables` is set: the store is the projection's store, the instance is the value at `instanceField`
   (top-level payload key; string), and the ids are the values of `idFields` (string or array of strings; other
   types are ignored).
3. The add-on name has the prefix `riela/memory-` or `riela/kv-`: `LocalOnlyDeliverable(kind: "memory" | "kv", path: <the
   add-on's database path: config key used by those add-ons; read their config names in
   `Sources/RielaCLI/ProductionNodeAdapter+*` for memory/KV; fall back to "cwd-local store">, bytes: nil)`.
4. Merge document entries by `(store, instance)`: ids unique and sorted, `producedByStepIds` unique and sorted.
   Deduplicate local-only entries by `(kind, path)`.
5. Output order: documents sorted by (store, instance ?? ""), then local-only entries sorted by (kind, path).

## Pitfalls

- A missing or mistyped payload field is skipped silently. Collection never throws; it runs during a handover.
- Executions with `importedFrom != nil` count as well, because the predecessor's deliverables stay deliverables.

## Tests (`DeliverableCollectorTests`, synthetic workflow and snapshot)

- a kaiba note-create step with noteId → one kaiba document with the instance
- two kaiba steps on the same instance → merged ids, both step ids listed
- a command node with `output.deliverables {store: "monja", instanceField: "baseUrl", idFields: ["taskId","commentIds"]}` → ids from a string and an array
- a riela KV add-on step → a localOnly `kv` entry
- a failed execution or an execution without accepted output → ignored
- output ordering is deterministic across two runs with shuffled input order

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-08-deliverable-collector/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-08-deliverable-collector/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "DeliverableCollectorTests" > tmp/work-handover/wh-08-deliverable-collector/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-08-deliverable-collector/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count.

## Done criteria

- [ ] The collector is implemented to the pinned API and rules
- [ ] The tests pass; the progress log is complete
