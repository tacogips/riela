# Implementation Plan: RielaApp Workflow Marketplace

- Status: Completed
- Design Reference: `design-docs/specs/design-rielaapp-workflow-marketplace.md`
- Created: 2026-07-15
- Last Updated: 2026-07-15

## Design Document Reference

- Source: `design-docs/specs/design-rielaapp-workflow-marketplace.md`
- Summary: Add a Marketplace pane to RielaApp where users register public GitHub
  repositories containing riela workflow bundles, browse the workflows with their
  descriptions (VSCode-extension style), and install one with an Install button. Fetching
  uses shallow `git clone` into an app-owned cache; installation reuses the existing
  managed workflow/package installers; registrations persist per profile in
  `daemon-workflows.json`.
- Scope included: repository reference model + persistence, catalog loader/scanner service,
  app-delegate handlers, Marketplace sidebar pane UI, unit tests.
- Scope excluded: CLI package-registry changes, GitHub API/auth/private repos,
  version/update management, non-macOS UI.

## Task Breakdown

### TASK-001 — Repository reference model + state persistence

- Status: COMPLETED
- Depends on: —
- Deliverables:
  - New `Sources/RielaAppSupport/RielaAppWorkflowRepositoryReference.swift`:
    `RielaAppWorkflowRepositoryReference` (owner/repository/branch, `id`, `cloneURL`,
    `webURL`, `parse(_:)`) and `RielaAppWorkflowRepositoryReferenceError`.
  - `RielaAppDaemonWorkflowState` (`Sources/RielaAppSupport/DaemonWorkflowSupport.swift`)
    gains `workflowRepositories` (CodingKey + `decodeIfPresent ?? []`) and
    `containsWorkflowRepository` / `addWorkflowRepository` / `removeWorkflowRepository`.
- Checklist:
  - [x] Accepts `https://github.com/owner/repo[.git]`, `.../tree/branch`, `owner/repo`.
  - [x] Rejects deeper tree paths, non-GitHub hosts, unsafe components.
  - [x] Legacy state JSON without the field still decodes.

### TASK-002 — Catalog scanner + git-backed loader

- Status: COMPLETED
- Depends on: TASK-001
- Deliverables:
  - New `Sources/RielaAppSupport/RielaAppWorkflowRepositoryCatalog.swift`:
    `RielaAppRemoteWorkflowListing`, `RielaAppWorkflowRepositoryCatalog`,
    `RielaAppWorkflowRepositoryCatalogScanner.scan(repositoryRoot:repositoryId:)`.
  - New `Sources/RielaAppSupport/RielaAppWorkflowRepositoryCatalogLoader.swift`:
    cache-dir resolution under `<appRoot>/marketplace-cache`, shallow clone with
    stderr capture, `forceRefresh`, typed `RielaAppWorkflowRepositoryCatalogError`.
- Checklist:
  - [x] Scanner finds nested bundles, skips `.git`/hidden/symlinks/invalid JSON.
  - [x] Package-contained workflows listed as `.packageWorkflow` with package-root
    install source and manifest title/description fallback.
  - [x] Deterministic ordering (by title, then workflowId).

### TASK-003 — App delegate marketplace handlers

- Status: COMPLETED
- Depends on: TASK-002
- Deliverables:
  - New `Sources/RielaApp/EntryPoint+WorkflowMarketplace.swift`:
    `addWorkflowRepository`, `removeWorkflowRepository`,
    `refreshWorkflowRepositoryCatalogs(forceRefresh:)`,
    `installMarketplaceWorkflow(repositoryId:relativePath:)`.
  - Delegate state (`EntryPoint.swift`): `marketplaceCatalogs`, `marketplaceErrors`,
    `marketplaceRefreshingRepositoryIds`; closures wired into
    `DaemonWorkflowWindowController` init; marketplace data passed via
    `refreshDaemonWorkflowWindow()` → `update(...)`.
- Checklist:
  - [x] Duplicate registration produces a status message, not a second entry.
  - [x] Save failure rolls back the in-memory state mutation.
  - [x] Fetch runs off the main thread; results published on `@MainActor`.
  - [x] Install path delegates to `importDaemonWorkflowOrPackageSourcesOnly`.

### TASK-004 — Marketplace pane UI

- Status: COMPLETED
- Depends on: TASK-003
- Deliverables:
  - New `Sources/RielaApp/DaemonWorkflowWindowController+MarketplacePane.swift`: pane
    build/rebuild with fingerprint, header (summary, Add Repository, Refresh), per-repo
    sections with Remove/Retry, workflow rows with description and Install/Installed
    button, empty state, add-repository prompt.
  - `DaemonWorkflowWindowController.swift`: `SidebarPane.marketplace`, stored marketplace
    inputs, new init closures (defaulted), `update(...)` defaulted parameters.
  - `DaemonWorkflowWindowController+SettingsShell.swift`: `sidebarMarketplaceButton`.
  - `DaemonWorkflowWindowController+Navigation.swift`: `showMarketplacePane()`,
    `showContentPane`/`goBack`/`updateSidebarSelection` participation.
- Checklist:
  - [x] Installed detection compares listing `workflowId` against profile
    `workflowSources`.
  - [x] Opening the pane triggers a lazy initial fetch for repos without catalogs.
  - [x] Existing panes/tests unaffected (all new init/update params defaulted).

### TASK-005 — Tests

- Status: COMPLETED
- Depends on: TASK-001..004
- Deliverables:
  - New `Tests/RielaAppSupportTests/RielaAppWorkflowRepositoryReferenceTests.swift`
    (parsing accept/reject matrix, id/cloneURL, state codable round-trip + legacy decode).
  - New `Tests/RielaAppSupportTests/RielaAppWorkflowRepositoryCatalogTests.swift`
    (fixture-directory scans: root bundle, nested bundle, package workflow fallback,
    invalid bundle skipped, symlink/.git ignored, ordering; loader cache-dir naming).
- Checklist:
  - [x] No network or git use in tests (scanner operates on temp fixture dirs).
  - [x] `swift test` green.

### TASK-006 — Verification + docs

- Status: COMPLETED
- Depends on: TASK-005
- Deliverables: `swift build` + `swift test` via the flake toolchain, swiftlint on changed
  files, README/docs touch-ups if behavior descriptions require it, progress log update.

## Module Status

| Module | Path | Status |
| --- | --- | --- |
| Repository reference | `Sources/RielaAppSupport/RielaAppWorkflowRepositoryReference.swift` | COMPLETED |
| State persistence | `Sources/RielaAppSupport/DaemonWorkflowSupport.swift` | COMPLETED |
| Catalog scanner | `Sources/RielaAppSupport/RielaAppWorkflowRepositoryCatalog.swift` | COMPLETED |
| Catalog loader | `Sources/RielaAppSupport/RielaAppWorkflowRepositoryCatalogLoader.swift` | COMPLETED |
| Delegate handlers | `Sources/RielaApp/EntryPoint+WorkflowMarketplace.swift` | COMPLETED |
| Marketplace pane | `Sources/RielaApp/DaemonWorkflowWindowController+MarketplacePane.swift` | COMPLETED |
| Controller wiring | `Sources/RielaApp/DaemonWorkflowWindowController.swift` (+SettingsShell, +Navigation) | COMPLETED |
| Tests | `Tests/RielaAppSupportTests/RielaAppWorkflowRepository*.swift` | COMPLETED |

## Dependencies

| Dependency | Direction | Notes |
| --- | --- | --- |
| `RielaAppManagedWorkflowInstaller` / `RielaAppManagedPackageInstaller` | reused | Install path unchanged |
| `RielaAppGitHubSourceMaterializer` | pattern reference | git invocation + safe-component rules mirrored |
| `RielaAppDaemonWorkflowStore` | reused | persists the new state field transparently |

## Completion Criteria

- All acceptance criteria in the design doc hold.
- `swift build` and `swift test` pass with the repository's Xcode toolchain wrapper.
- No changes to CLI behavior or non-macOS builds (`RielaAppUnsupported` untouched).

## Progress Log

- 2026-07-15: Plan created alongside design doc; implementation started on branch
  `feature/rielaapp-workflow-marketplace`.
- 2026-07-15: TASK-001..006 implemented. Scanner initially derived relative paths from
  `contentsOfDirectory(at:)` URLs, which canonicalize `/var` to `/private/var` and broke
  prefix matching; fixed by building child URLs from directory names. Full suite green
  (`swift test`: 2042 tests, 0 failures, 4 skipped); swiftlint clean on changed files
  (moved `removeDaemonWorkflowDirectory` into a same-file extension to stay under the
  800-line type-body limit).
