# Riela Swift Native Migration Design: Cutover and Deletion Readiness

## TASK-009 Final Parity, Security, And Cutover Gate

TASK-009 is the final issue-resolution gate before release packaging may switch
from the TypeScript/Bun executable to the Swift executable. It must collect
fresh deterministic evidence, harden only the parity or security gaps exposed by
that evidence, update the gate manifest only for gates whose verification has
passed, and hand the result to adversarial implementation review. TASK-009 must
not remove the TypeScript/Bun runtime, publish release assets, commit tap
formula changes, replace `dist/homebrew` production archives, or make Swift the
default Homebrew source before the review gate is accepted.

Cutover gate ownership:

- `packaging/homebrew/swift-cutover-gates.json` remains the machine-readable
  cutover manifest. A gate status may move from `blocked` only when the
  implementation records the exact command, fixture or archive path, and result
  that proves the gate in the current branch.
- `allowsProductionCutover` remains `false` until every required gate is passed
  and the `task009-adversarial-review` gate records an accepted high-risk
  review decision. If any required gate remains blocked, the production runtime
  remains `typescript-bun`.
- Gate evidence must be local, deterministic, and replayable. It may use
  injected stores, clocks, process runners, dry-run adapters, local fixture
  manifests, local event fixtures, local GraphQL DTO fixtures, local hook
  fixtures, and archived Swift binaries. It must not require live LLM
  credentials, network access, package checkout mutation, GitHub release upload,
  tap mutation, or live long-running server loops.
- The archived Swift executable must prove `--help`, workflow validation,
  workflow inspect, and deterministic mock run behavior from inside the staged
  archive, not only through `swift run`.

Required TASK-009 evidence:

- TypeScript/Bun baseline: typecheck, Biome lint, and project-scope workflow
  validation must pass so Swift cutover does not hide a broken fallback runtime.
- Swift package verification: the explicit Xcode Swift toolchain must report its
  version and `swift test` must pass all Swift tests in the current branch.
- CLI parity: Swift `workflow validate`, `workflow inspect`, and deterministic
  `workflow run --mock-scenario` must pass against repository fixtures.
- Package validation parity: Swift package manifest loading and validation must
  match the local package fixture contract, including safe path handling and
  deterministic diagnostics.
- Event dry-run parity: Swift event-source dry-run mapping must preserve trigger
  payload, runtime variables, mailbox bridge policy, reply dispatch descriptors,
  and no-side-effect behavior from local fixtures.
- GraphQL manager-control parity: Swift DTO and mutation/request descriptors
  must preserve session inspection, manager-control input shapes, idempotency
  and result fields, and deterministic schema descriptors without requiring an
  HTTP server.
- Hook context parity: Swift hook parsing and recording must preserve
  `agentSessionId`, backend metadata, optional raw capture controls, and
  credential/path redaction in persisted or test-visible records.
- Adapter output normalization: Swift adapter output, JSON candidate extraction,
  output-envelope handling, invalid-output failure, and redaction must remain
  shared across local agents and official SDK adapters without giving adapters
  ownership of workflow publication.
- SQLite persistence parity: Swift SQLite-backed or SQLite-contract session and
  workflow message persistence must prove runtime-generated communication ids,
  ordered message resolution, failed-write handling, and no legacy
  inbox/outbox/mailbox publication path.
- macOS archive smoke: the Swift readiness archive must contain only the
  expected payload, have a valid `.sha256` sidecar, avoid machine-local absolute
  path leakage, and pass archived binary smoke commands.

Security and boundary checks:

- External process execution remains explicit argv execution with injectable
  runners, bounded deadlines, descriptor isolation, and credential redaction.
- Candidate-path staging, accepted-output artifacts, workflow message
  publication, communication ids, and final root output selection remain
  runtime-owned. Adapters, add-ons, event dry-runs, GraphQL descriptors, hooks,
  and packaging scripts must not publish workflow messages or invent
  communication ids.
- Cursor-specific behavior remains isolated in `CursorCLIAgent`; TASK-009 must
  not expose Cursor CLI modes, stream formats, auth assumptions, or
  `official/cursor-sdk` compatibility through provider-neutral core, add-on,
  event, GraphQL, hook, server, or packaging surfaces.
- Swift formula previews and readiness archives are pre-cutover artifacts only.
  Production Homebrew archive names under `dist/homebrew` remain TypeScript/Bun
  owned until TASK-009 review accepts the full cutover.

Codex-reference mapping:

- Step 1 for TASK-009 used `../../codex-agent` as the preferred reference root
  and found it unavailable, so TASK-009 must continue treating current Riela
  TypeScript adapters, runtime code, and pinned package contracts as the local
  behavioral reference.
- The adjacent `../codex-agent` checkout may remain a reference-only structural
  comparison for package executable metadata, but TASK-009 must not copy
  codex-agent code or introduce npm publishing behavior.
- Intentional Swift divergence remains structural only: repository-owned agent
  integrations are SwiftPM targets, while backend strings, normalized adapter
  envelopes, readiness categories, and runtime-owned publication semantics stay
  compatible.

## Branch Production Swift Homebrew Release Cutover

The dedicated branch-local release packaging cutover is the first step after
TASK-009 acceptance that may change production Homebrew packaging defaults. Its
scope is narrower than runtime migration: it switches the release artifact and
formula source from Bun-compiled archives to Swift executable archives while
preserving the existing CLI command name, workflow behavior, and installer
payload shape.

Cutover inputs:

- `impl-plans/completed/swift-native-migration.md` and
  `impl-plans/completed/swift-native-migration-task-009-final-cutover-gate.md`
  are accepted evidence that the Swift runtime parity gates have completed.
- `packaging/homebrew/swift-cutover-gates.json` is the machine-readable source
  for cutover readiness. At cutover start, all non-review gates are passed, but
  `productionRuntime` is still `typescript-bun`, `homebrewFormulaSource` is
  still `bun-archive`, `allowsProductionCutover` is still `false`, and
  `task009-adversarial-review` is blocked only because production Homebrew has
  not yet been switched.
- The existing production release scripts and formula renderer are the behavior
  boundary: the new production Swift path must produce archives and checksums
  that the renderer can consume without relying on the pre-cutover readiness
  directory.

Production artifact contract:

- The production runtime marker becomes `swift-native`, and the formula source
  marker becomes `swift-executable-archive` or an equivalent explicit Swift
  archive value after the dedicated cutover verification passes.
- Production archives move to `dist/homebrew` and keep the installer-visible
  archive shape `bin/riela` plus `README.md`. The command installed by
  Homebrew remains `riela`.
- Production Swift archive names should use the existing release naming
  convention consumed by the formula renderer:

  ```text
  dist/homebrew/riela-<version>-darwin-arm64.tar.gz
  dist/homebrew/riela-<version>-darwin-x64.tar.gz
  ```

- Linux release archive behavior must fail closed until there is an explicit
  Swift Linux build contract. The cutover must not silently keep Bun-built Linux
  archives while marking the overall production runtime as Swift.
- Each production archive must have a sibling `.sha256` sidecar generated from
  the archive basename in the archive directory, with no machine-local absolute
  path leakage.

Formula and script behavior:

- The production Homebrew formula renderer reads `dist/homebrew` checksums and
  emits macOS URLs for Swift executable archives. The formula description should
  no longer describe the installed tool as TypeScript/Bun once the cutover is
  accepted.
- `RIELA_RELEASE_BASE_URL` remains the only URL-base override for local formula
  smoke tests and release upload staging.
- The Swift readiness builder remains historical cutover evidence unless it is
  intentionally collapsed into the production release builder. Production
  scripts must be dry-run friendly where practical, deterministic, explicit
  about artifact directories, and free of release upload or tap mutation side
  effects.
- GitHub release upload and Homebrew tap commits remain operator actions after
  archive and formula verification. The cutover may update scripts and docs for
  those actions, but must not perform publication during verification.

Gate manifest transition:

- The dedicated cutover may resolve the `task009-adversarial-review` blocked
  state because TASK-009 review already accepted with no high or mid findings
  in workflow session
  `riel-codex-design-and-implement-review-loop-1781261544-53db3135`.
- `allowsProductionCutover` may become `true` only when production archive
  generation, formula rendering, local formula smoke, manifest JSON validation,
  and source/path leakage checks pass in the current branch.
- Historical TASK-009 evidence should remain readable in
  `packaging/homebrew/swift-cutover-gates.json`; the dedicated release cutover
  should add or update a separate production cutover evidence block rather than
  erasing the prior readiness trail.

Required production cutover verification:

- `git diff --check`
- `jq empty packaging/homebrew/swift-cutover-gates.json`
- Swift toolchain version through the explicit Xcode Swift path
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
- production Swift archive dry-run, when available
- production Swift archive build for `darwin-arm64` on an arm64 macOS host and
  `darwin-x64` on an x64 macOS host or other explicitly supported deterministic
  builder
- `tar -tzf` for every produced production archive, proving the payload is only
  `./`, `./bin/`, `./bin/riela`, and `./README.md`
- checksum validation for every produced production archive
- repository search against checksum files and generated formula proving no
  `/Users/`, `/home/`, or current checkout path appears
- local Homebrew formula render using `RIELA_RELEASE_BASE_URL="file://$PWD/dist/homebrew"`
- `brew install`, `brew test`, `riela --help`, and at least one
  deterministic workflow command through the installed formula when Homebrew is
  available; otherwise record the missing Homebrew tool as a blocker, not a
  passed gate

Rollout constraints:

- This cutover changes branch production packaging defaults only; it does not
  delete TypeScript/Bun source, remove fallback test coverage, publish GitHub
  releases, or push tap changes.
- If any production archive, formula, checksum, or Homebrew smoke gate remains
  blocked, `allowsProductionCutover` stays `false` and the production runtime
  marker must not claim Swift production.
- Cursor-specific behavior remains isolated in `CursorCLIAgent`; release
  packaging must not add Cursor CLI modes, stream handling, auth checks, or
  `official/cursor-sdk` behavior to provider-neutral packaging scripts.

## Data Flow

The Swift runtime should keep the same high-level execution flow as the TypeScript runtime:

1. `RielaCLI`, GraphQL, server, or library entrypoints resolve a workflow through the same direct/project/user/package discovery rules.
2. `RielaCore` decodes authored workflow JSON, validates step-addressed structure, resolves backend identifiers, and exposes value types with stable JSON encoding.
3. Runtime orchestration creates or resumes a persisted session, owns queue state, owns workflow messages, and selects the next step.
4. Native node execution and add-on execution stay behind explicit engine boundaries. Add-ons receive declarative config and runtime-provided context, not engine internals.
5. Agent nodes dispatch through `RielaAdapters` into one backend-specific target. Provider output is normalized to `provider`, `model`, `promptText`, `completionPassed`, `when`, and `payload`.
6. The runtime validates the output contract, publishes messages, updates session state, and exposes status through CLI, GraphQL, and server inspection.

Swift code should avoid introducing a second workflow contract. Existing workflow JSON fixtures, node JSON fixtures, package manifests, event bindings, and hook snippets are the migration compatibility source.

## Migration Strategy

1. Establish a compiling SwiftPM package with target boundaries matching the current workspace.
2. Port `riela-core` model and validation code first, because every other package depends on it.
3. Port adapter dispatch and local agent subprocess wrappers, including `codex-agent`, `claude-code-agent`, and `cursor-cli-agent` as independent Swift targets.
4. Port runtime storage, workflow execution, node add-ons, and event sources behind the same public contracts.
5. Replace the CLI entry point only after Swift runtime can validate, inspect, and run deterministic mock workflows.
6. Switch branch production release packaging and Homebrew artifacts to the
   Swift executable after TASK-009 parity gates pass and the dedicated
   production archive/formula gates pass.

Cutover constraints:

- TypeScript/Bun remains the fallback runtime until Swift can pass fixture parity for validation, inspect, deterministic run, package validation, event trigger dry-runs, GraphQL manager control, hook context parsing, and adapter output normalization.
- Swift packaging must not replace release artifacts until the Swift executable
  path, macOS archive names, production `dist/homebrew` archive path, Homebrew
  formula source, and smoke tests are updated and verified by the dedicated
  production cutover after TASK-009 acceptance.
- Swift target names can use Swift-style PascalCase, but public backend strings, workflow JSON fields, package identifiers, and documented CLI behavior must remain stable.
- The migration should not include a native macOS UI in the runtime parity milestone. UI design can begin after CLI/runtime parity is testable.

## TypeScript Deletion-Readiness TODO Loop

Swift production packaging readiness is not TypeScript source deletion
readiness. The migration must keep TypeScript/Bun source, tests, package
metadata, CLI entrypoints, server surfaces, GraphQL contracts, event sources,
workflow package behavior, persistence, release tooling, documentation, and
fallback verification in place until a tracked deletion-readiness gate proves
full Swift parity.

The tracked gate is `packaging/swift-deletion-readiness.json`. The first
bounded implementation slice must keep `allowsTypeScriptDeletion=false`,
`typeScriptSourceDeletionReady=false`, and `migrationStatus=incomplete`. A later
deletion-ready state may only set both deletion flags true when
`migrationStatus=deletion_ready` and every required domain has durable accepted
evidence:

- package build and package metadata parity
- CLI validate, inspect, run, resume, rerun, status, and package command parity
- server runtime and HTTP contract parity
- GraphQL manager-control, session, and DTO parity
- event source validation, dry-run, emit, serve, replay, and chat gateway parity
- workflow package install, checkout, registry, skill projection, and add-on
  contract parity
- persistence, workflow session, message store, and resume/rerun parity
- release, Homebrew, archive, checksum, and rollback parity
- documentation and user-facing migration guidance parity
- test parity across Swift package tests, TypeScript baseline checks, workflow
  validation, release gates, and fixture compatibility
- `claude-code-agent`, `codex-agent`, and `cursor-cli-agent` behavior parity
  against the current TypeScript adapters and pinned package contracts

Deletion-ready evidence must be current and review-bound, not self-attested.
Each required domain must include commands that actually ran, durable command
result artifact references, parseable ISO-8601 `lastVerifiedAt`, matching branch
and commit evidence, accepted review workflow/node ids, and explicit
non-blocking accepted-review severity evidence. Durable evidence artifacts must
resolve to successful command-result metadata bound to the domain id, listed
command, branch, commit, workflow id, and the command execution node id. Review
acceptance remains separate in `acceptedReviewWorkflowId`,
`acceptedReviewNodeId`, and `acceptedReviewFindingSeverities`. Unknown, blank,
blocking, stale, unresolved, source-only, placeholder, or review-node-spoofed
command evidence keeps TypeScript deletion blocked.

The `<rielflow-checkout>` checkout is reference-only for this
deletion-readiness loop. Until dedicated Swift references are accepted,
`CodexAgent`, `ClaudeCodeAgent`, and `CursorCLIAgent` parity is measured against
the current Riela TypeScript adapters, pinned package contracts, and the
concrete reference files listed in Reference Mapping. Reference paths are used
only for behavioral comparison and verification framing, not for copied source.
