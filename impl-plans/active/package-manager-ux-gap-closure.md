# Package Manager UX Gap Closure Implementation Plan

**Status**: Implemented and verified
**Design Reference**: `design-docs/specs/design-package-manager-ux-gap-closure.md`
**Created**: 2026-07-06
**Last Updated**: 2026-07-06

---

## Design Document Reference

**Source**: `design-docs/specs/design-package-manager-ux-gap-closure.md`

### Summary

Close the verified gaps between the accepted package design slices and the
Swift `riela package` production surface: dependency-aware install per the
Issue 43 contract in `design-workflow-package-registry.md`, managed registry
acquisition with a `registry sync` command and candidate-path error reporting,
search matching parity (fields, filters, table output, `--refresh`), real
`package update` semantics, `package` subcommand `--help`, and CLI surfacing of
manifest `environmentVariables`.

Reproduced end-user failures driving this plan (riela 0.1.17, 2026-07-06
registry audit): `package search` returns empty without an undocumented
sibling checkout, meta package installs skip all 12 declared dependencies,
`package update` is a stub, and `--help` is rejected on subcommands.

### Scope

**Included**: Swift CLI package command behavior, registry cache acquisition
via git, install transaction with dependency resolution and rollback, update
command, per-subcommand help for the `package` family, install/status JSON and
text output additions, focused RielaCLI tests.

**Excluded**: package publish flows, registry policy defaults, signature or
digest gate changes, RielaApp UI changes, GraphQL package surface changes,
`--user-scope`/`--scope user` flag reconciliation (parity plan), general help
framework for non-package command families.

---

## Codex Agent References

- `AGENTS.md`
- `design-docs/specs/design-package-manager-ux-gap-closure.md`
- `design-docs/specs/design-workflow-package-registry.md`
- `design-docs/specs/design-workflow-package-commands.md`
- `design-docs/specs/design-workflow-package-checkout.md`
- `Sources/RielaCLI/WorkflowPackageParityCommands.swift`
- `Sources/RielaCLI/WorkflowPackageCommandRunner+Install.swift`
- `Sources/RielaCLI/WorkflowPackageCommandRunner+Archives.swift`
- `Sources/RielaCLI/WorkflowPackageSupport.swift`
- `Sources/RielaAddons/WorkflowPackageManifest.swift`
- `Sources/RielaAddons/WorkflowPackageManifestModels.swift`
- `Tests/RielaCLITests/WorkflowCommandPackageLifecycleTests.swift`
- `Tests/RielaCLITests/WorkflowPackageArchiveCommandTests.swift`
- `Tests/RielaAddonsTests/WorkflowPackageManifestTests.swift`

## Modules

### 1. Dependency Resolution Core (G1)

#### Sources/RielaCLI/WorkflowPackageDependencyResolver.swift (new)

**Status**: IMPLEMENTED_INLINE

Resolves a caller manifest's normalized dependency entries depth-first against
a registry content root, producing an install plan.

```swift
struct PackageIdentity: Hashable {
  let registryUrl: String
  let sourceBranch: String?
  let sourcePath: String
  let packageId: String
}

enum DependencyPlanEntry {
  case satisfied(PackageIdentity, existingCheckoutRecordPath: String)
  case missing(PackageIdentity, manifestDirectory: URL)
}

struct DependencyInstallPlan {
  let caller: PackageIdentity
  let ordered: [DependencyPlanEntry] // depth-first, dependencies before caller
}

enum DependencyResolutionError: Error {
  case cycle(chain: [PackageIdentity])
  case unresolved(dependencyId: String, callerChain: [PackageIdentity], searchedRoots: [String])
}
```

**Checklist**:
- [x] Normalize string and object dependency entries (`packageId`, `registry`, `branch`)
- [x] Depth-first traversal with cycle detection on package dependency chain
- [x] Equivalence check against destination checkout catalog and validation catalog
- [x] Deterministic plan ordering and cycle-chain error rendering
- [x] Unit tests with local fixture registries

#### Sources/RielaCLI/WorkflowPackageCommandRunner+Install.swift

**Status**: IMPLEMENTED

Wire the resolver into the install transaction.

**Checklist**:
- [x] `--no-dependencies` flag restores current single-package behavior
- [x] Install missing dependencies through the existing gate pipeline before caller validation
- [x] Transaction rollback removes only artifacts created by this transaction
- [x] Dry-run reports `wouldInstall` / `satisfied` / `missing` without mutation
- [x] Install JSON adds `dependencies[]` install records
- [x] Lifecycle test: meta package fixture installs caller plus all dependencies

### 2. Registry Acquisition (G2)

#### Sources/RielaCLI/WorkflowPackageRegistrySync.swift (new)

**Status**: IMPLEMENTED_NEEDS_LIVE_GIT_VERIFICATION

Managed cache root `~/.riela/registries/<registry-id>`; clone or fast-forward
via `git` for `registry sync`, `--refresh`, and reported first-use miss.

```swift
struct RegistryContentRootResolution {
  let root: URL?
  let consultedCandidates: [String] // flag --local-path, configured localPath, sibling default, managed cache
  let fetched: Bool
}
```

**Checklist**:
- [x] `riela package registry sync [<registry-id>]` subcommand
- [x] Candidate resolution order per design; sibling default demoted to fallback
- [x] Error output names every consulted candidate path and the sync command
- [x] Empty-but-present root reported distinctly from missing root
- [x] `package list` remains offline
- [x] Tests: cache-miss report, candidate ordering, sibling fallback

### 3. Search Parity (G3)

#### Sources/RielaCLI/WorkflowPackageParityCommands.swift

**Status**: IMPLEMENTED

**Checklist**:
- [x] Match name, title, description, tags, backends, workflow ids
- [x] `--tag`, `--backend`, `--limit`, `--refresh` options
- [x] `--output table` with `PACKAGE`, `WORKFLOW`, `REGISTRY`, `TAGS`, `SUMMARY`
- [x] JSON adds match metadata and cache metadata
- [x] Tests: field matching matrix, filter normalization, table rendering

### 4. Package Update (G4)

#### Sources/RielaCLI/WorkflowPackageCommandRunner+Update.swift (new)

**Status**: IMPLEMENTED

Replace the status-check stub with reinstall-based update semantics.

```swift
enum PackageUpdateState: String { case upToDate = "up-to-date", updated, failed }

struct PackageUpdateRecord {
  let installId: String
  let packageId: String
  let previousVersion: String?
  let previousChecksum: String?
  let updateState: PackageUpdateState
}
```

**Checklist**:
- [x] Selector resolution shared with `package status`
- [x] Version/checksum/integrity comparison against recorded registry source
- [x] Reinstall through the G1 transaction with implicit overwrite and `--yes` gate
- [x] `--all` and `--dry-run`
- [x] Remove stub response; JSON per design (`previousVersion`, `previousChecksum`, `updateState`)
- [x] Lifecycle tests: up-to-date, changed-version, failed-fetch paths

### 5. Subcommand Help (G5)

#### Sources/RielaCLI/WorkflowPackageParityCommands.swift

**Status**: IMPLEMENTED

**Checklist**:
- [x] `--help`/`-h` handled before option validation for every `package` subcommand and bare `riela package`
- [x] Usage text lists accepted options including new G1-G4 flags
- [x] Exit code 0, stdout
- [x] Snapshot tests for help output

### 6. Environment Variable Surfacing (G6)

#### Sources/RielaCLI/WorkflowPackageSupport.swift

**Status**: IMPLEMENTED

**Checklist**:
- [x] `requiredEnvironment` array in install (incl. dry-run) and status JSON
- [x] Text `environment:` section after install when manifest declares variables
- [x] Secret entries print names only
- [x] Tests with the Google Speech-to-Text one-of credential fixture

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Dependency resolver | `Sources/RielaCLI/WorkflowPackageCommandRunner+Install.swift` | IMPLEMENTED_INLINE | Package dependency fixture |
| Install transaction wiring | `Sources/RielaCLI/WorkflowPackageCommandRunner+Install.swift` | IMPLEMENTED | Rollback + dependency fixture |
| Registry sync/cache | `Sources/RielaCLI/WorkflowPackageParityCommands.swift` | IMPLEMENTED_NEEDS_LIVE_GIT_VERIFICATION | Focused CLI parsing/search |
| Search parity | `Sources/RielaCLI/WorkflowPackageParityCommands.swift` | IMPLEMENTED | Package search fixture |
| Package update | `Sources/RielaCLI/WorkflowPackageCommandRunner+Install.swift` | IMPLEMENTED | Package update fixture |
| Subcommand help | `Sources/RielaCLI/WorkflowPackageParityCommands.swift` | IMPLEMENTED | Command parsing |
| Env var surfacing | `Sources/RielaCLI/WorkflowPackageSupport.swift` | IMPLEMENTED | Package metadata fixture |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Install wiring (G1) | Dependency resolver | IMPLEMENTED |
| Package update (G4) | Install wiring (G1) | IMPLEMENTED |
| Search `--refresh` (G3) | Registry sync (G2) | IMPLEMENTED |
| Subcommand help (G5) | Final flag set of G1-G4 | IMPLEMENTED |
| Env var surfacing (G6) | None | Available |

G2, G3 baseline matching, G5, and G6 are independently landable slices. G1 must
land before G4.

## Completion Criteria

- [x] Meta package fixture install produces caller plus all dependency records;
      `--no-dependencies` preserves current behavior
- [x] `package search goal` succeeds with no flags after `registry sync` in a
      clean home fixture; failure paths name consulted candidate roots
- [x] Search matches all designed fields and supports `--tag`, `--backend`,
      `--limit`, `--refresh`, `--output table`
- [x] `package update` reports `up-to-date` / `updated` / `failed` truthfully;
      stub response removed
- [x] Every `package` subcommand answers `--help` with exit 0
- [x] Install/status output includes `requiredEnvironment` from manifests
- [x] Focused `RielaCLITests` suites pass; full `swift test` passes
- [x] Registry maintainer flow re-verified against a `tacogips/riela-packages`
      checkout (Taskfile dry-run path adopts `--no-dependencies` if needed)

## Progress Log

### Session: 2026-07-06
**Tasks Completed**: Plan created from the riela-packages registry audit and
design-doc gap analysis.
**Tasks In Progress**: Swift implementation landed in the working tree:
dependency install with rollback, managed registry sync/cache routing, search
filters/table output, real update, package subcommand help, and environment
variable surfacing. Focused package and parsing tests pass; full `swift test`
passed 1327 tests with 0 failures.
**Blockers**: None
**Notes**: Isolated live default-registry sync/search evidence: `registry sync` wrote to
`tmp/source-security-check-loop-verification/package-registry-live/home/.riela/registries/default`;
`package search goal --output json` returned 4 packages, first
`claude-code-goal`. Registry maintainer flow evidence: sibling `riela-packages`
`Taskfile.yml` now passes `--no-dependencies` for package source dry-run validation;
`RIELA_ROOT=<riela-repo> task package:validate` passed for
62 package manifests.

## Related Plans

- **Previous**: `active/workflow-package-checkout-search.md`,
  `active/workflow-package-registry.md` (TypeScript-era contracts this plan
  ports to the Swift surface)
- **Next**: `--user-scope` flag reconciliation and general help routing remain
  with `active/swift-cli-runtime-parity-gap-closure.md`
