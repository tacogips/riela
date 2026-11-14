# wh-09: Handover sinks (store, kaiba, gitRef, file, command) and locator verification

```json
{
  "planId": "wh-09-handover-sinks",
  "planPath": "impl-plans/active/wh-09-handover-sinks.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaCLI/HandoverSinks/StoreHandoverSink.swift",
    "Sources/RielaCLI/HandoverSinks/KaibaHandoverSink.swift",
    "Sources/RielaCLI/HandoverSinks/GitRefHandoverSink.swift",
    "Sources/RielaCLI/HandoverSinks/FileHandoverSink.swift",
    "Sources/RielaCLI/HandoverSinks/CommandHandoverSink.swift",
    "Sources/RielaCLI/HandoverSinks/HandoverSinkFactory.swift",
    "Tests/RielaCLITests/HandoverSinkTests.swift",
    "impl-plans/progress/wh-09-handover-sinks.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-09-handover-sinks.md"
}
```

## Intent and context

Sinks mirror the sealed packet so that a successor or a human can read it without the controller. The store row stays
canonical (design §3.6, §8, §14 "sinks are outbound"; Q2/Q8 defaults: store only unless configured on
the task or workflow, or via `--sink`). Protocol `HandoverSink`, `HandoverSinkConfig`, `HandoverSinkRef` (with
`serialized`/`parse`) and `JSONCanonical` are in wh-01.

Non-goals: calling sinks at seal time (wh-04 coordinator), CLI flags (wh-15), gc (wh-13), and profile-level
sink config (R6).

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-09-handover-sinks/`,
writePaths only, arm64 logs; tests use temp directories and temp git repos under `tmp/`; no project-repo git
state changes; own progress log).

## Deliverables

Every sink's `write` returns `HandoverSinkRef(kind, locator, digest: packet.digest, writtenAt: now)`. `read`
returns exactly the canonical packet bytes it stored.

- `HandoverSinkVerification.verify(bytes: Data, ref: HandoverSinkRef) throws -> HandoverPacket`. Decode the bytes with
  `JSONCanonical.decoder()`, recompute `canonicalDigest()`, and require equality with **both** `packet.digest` and
  `ref.digest`. Otherwise throw `HandoverSinkError.digestMismatch(expected:actual:)`. This function is the only
  verification path. Callers never trust the bytes without it.
- **Store**: `init(store: WorkStore, hostId: String)`. `write` is a no-op returning locator
  `<hostId>/<taskId>/<handoverId>`. `read` returns `JSONCanonical.encode(store.loadHandover(...))`.
- **File**: `init(root: String)`. Write `<root>/handovers/<taskId>/<handoverId>.json` (canonical bytes) and
  `.md` (brief) through a temp file and atomic rename. If the target exists with different bytes, refuse; identical bytes are OK.
  The locator is the absolute json path. **This layout is also used by wh-13 gc; do not change it.**
- **Command**: `init(argv: [String], timeoutSeconds: 30)`. `write` executes argv directly (no shell) with
  the packet bytes on stdin. It needs exit 0, and the first stdout line, trimmed, is the id (non-empty, ≤ 256 chars, no whitespace).
  `read` executes `argv + ["--read", id]` and returns stdout. Use the process helper `LoopNotificationDispatcher.runProcessChannel`
  or `LocalProcess` style. Pick the existing helper that returns stdout, and record which.
  A non-zero exit, a timeout or an empty id is an error. This is how monja is a sink (design §8).
- **GitRef**: `init(repositoryRoot: String, remote: String)`. `write`: `git hash-object -w --stdin` → blob;
  `git update-ref refs/riela/handovers/<taskId>/<handoverId> <blob>`; `git push <remote>
  refs/riela/handovers/<taskId>/<handoverId>:refs/riela/handovers/<taskId>/<handoverId>` (never force; if the remote ref
  exists with a different sha → error). The locator is `<remote> refs/riela/handovers/<taskId>/<handoverId>`. `read`: fetch that
  ref into the same local ref, then `git cat-file blob <ref>`. Use `GitCommandRunning`/`FoundationGitCommandRunner`.
- **Kaiba**: `init(client: any KaibaHandoverNoteClient, instanceId: String, notebookId: String?)`, with
  `protocol KaibaHandoverNoteClient: Sendable { func createNote(instanceId:notebookId:title:bodyMarkdown:tags:) async throws -> String; func getNote(instanceId:noteId:) async throws -> String }`.
  The body is the brief + `"\n\n```riela-handover-packet\n" + <canonical json as UTF-8> + "\n```\n"`. Tags are
  `riela-handover` and `task:<taskId>`. The title is `Handover <handoverId> (<taskId>)`. `read` extracts the fenced block.
  The production client `KaibaAddonCatalogNoteClient` builds a `WorkflowAddonExecutionInput` for `kaiba/note-create`
  and `kaiba/note-get` and calls `KaibaAddonCatalog.execute(_:environment:)` (as `ProductionNodeAdapter.swift:502`
  does). Read the config and input names in `Sources/RielaKaibaAddons/KaibaNoteAddons.swift`. The locator is `<instanceId>/<noteId>`.
- **Factory** `HandoverSinkFactory`:
  - `static func mergedConfigs(task: WorkTask, workflow: WorkflowDefinition, cliKinds: [HandoverSinkKind]) -> [HandoverSinkConfig]`.
    The order is `task.guardPolicy.handover?.sinks`, then `workflow.handover?.sinks`, then one default config per CLI kind not
    already present. `.store` is dropped (always implicit). Deduplicate by kind + target field.
  - `static func make(_ configs: [HandoverSinkConfig], context: HandoverSinkContext) throws -> [any HandoverSink]`,
    where `HandoverSinkContext {hostId, storeRoot, repositoryRoot: String?, store: WorkStore, environment}`. A missing required
    field (kaiba without an instance, command without argv, gitRef without a repository root) throws a clear error.
  - `static func reader(for ref: HandoverSinkRef, context:) throws -> any HandoverSink` for `--packet <locator>`.

## Pitfalls

- Fail-closed quoting: never build a shell string. argv only.
- A file sink root outside the store is fine, but refuse a relative `path`.
- A sink write happens after the store transaction. Errors propagate to the coordinator, which records publication evidence.
  Do not swallow them here.

## Tests (`HandoverSinkTests`)

Build a sealed packet in the test via wh-01 `HandoverPacket(...).sealed()`.
- file: write → read → verify returns an equal packet; overwriting with different bytes → error; the `.md` exists
- command: a fixture script under `tmp/…` stores stdin by id and prints it; round-trip plus verify; a script exiting 3 → error; an empty id → error
- gitRef: temp repo + bare remote; write → a fresh second clone reads through the reader → verify
- kaiba: a fake client round-trip; the body contains the fenced block and the brief; tags asserted
- store: a temp WorkStore holding a saved packet → read → verify
- a tampered byte → `digestMismatch`; a locator `serialized` → `reader(for:)` resolves the right kind
- `mergedConfigs` ordering and deduplication

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-09-handover-sinks/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-09-handover-sinks/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverSinkTests" > tmp/work-handover/wh-09-handover-sinks/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-09-handover-sinks/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count. The acceptance signal "kaiba, gitRef, file and command sinks round-trip the
packet with digest verification" is proven here: record the four test names in the progress log.

## Done criteria

- [x] The five sinks, verification and factory are implemented to the pinned shapes
- [x] The round-trip and tamper tests pass
- [x] The progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; implemented in `d043cbad` (waves 1-2), acceptance recorded in `7182232d`. Evidence: `impl-plans/progress/wh-09-handover-sinks.md`. Archived to `impl-plans/completed/`.
