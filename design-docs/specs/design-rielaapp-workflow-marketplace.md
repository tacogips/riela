# Design: RielaApp Workflow Marketplace (Registered GitHub Repositories)

- Date: 2026-07-15
- Status: Draft
- Compatibility: macOS RielaApp only (`#if os(macOS)`). No CLI behavior changes. Profile state
  format gains one optional field (backward compatible).

## Goal

Let RielaApp users install workflows the way VSCode users install extensions:

1. Register one or more GitHub repositories that contain riela workflow bundles.
2. Browse a list of the workflows stored in those repositories, with each workflow's
   name and description.
3. Press an **Install** button on a row to install that workflow into the active
   RielaApp profile, after which it appears under Workflow Sources and can back
   instances.

Today the only remote acquisition path in RielaApp is a one-shot "Import URL" prompt that
requires the user to already know the exact GitHub `tree` URL of a single workflow
directory. There is no browsing, no descriptions, and the repository URL is not remembered.

## Code-Verified Current State

- `Sources/RielaApp/DaemonWorkflowWindowController+SourcesPane.swift:60` — "Import URL"
  button in the Workflow Sources pane triggers `addURL`.
- `Sources/RielaApp/DaemonWorkflowWindowController+Prompts.swift:508` — `promptForImportURL`
  asks for a GitHub tree URL (`https://github.com/owner/repo/tree/branch/path`).
- `Sources/RielaApp/EntryPoint+DaemonSourceURLImport.swift:6` —
  `addDaemonWorkflowSourceOnlyURL(_:)` materializes the URL with
  `RielaAppGitHubSourceMaterializer` on a detached task, imports the resulting directory via
  `importDaemonWorkflowOrPackageSourcesOnly`, then deletes the temp checkout.
- `Sources/RielaAppSupport/RielaAppGitHubSourceMaterializer.swift:52` — sparse, depth-1
  `git clone` of a single directory; URL parsing accepts only `tree` URLs
  (`parseDirectoryReference`, line 65); path components validated by `isSafeComponent`
  (line 138).
- `Sources/RielaApp/EntryPoint.swift:628` — `importDaemonWorkflowOrPackageSourcesOnly`
  classifies each source via `RielaAppImportSourceClassifier`
  (`Sources/RielaAppSupport/RielaAppManagedWorkflowInstaller.swift:220`) and installs it with
  `RielaAppManagedWorkflowInstaller.installWorkflowDirectoryResult` (workflow directories,
  line 53) or `RielaAppManagedPackageInstaller.installPackageSourceResult` (package
  directories / archives, line 129). Both copy into the active profile roots
  (`~/.riela/rielaapp/profiles/<name>/workflows|packages`,
  `Sources/RielaAppSupport/DaemonWorkflowSupport.swift:221`).
- `Sources/RielaAppSupport/DaemonWorkflowSupport.swift:248` — per-profile persisted state
  `RielaAppDaemonWorkflowState` (`daemon-workflows.json`): `preferences`,
  `workflowDirectories`, `projectDirectories`, `assistant`. Decoding uses
  `decodeIfPresent` for every field, so adding fields is backward compatible.
- `Sources/RielaApp/DaemonWorkflowWindowController.swift:193` — `SidebarPane` enum
  (`instances | sources | assistant | profiles`); sidebar buttons are built in
  `DaemonWorkflowWindowController+SettingsShell.swift:300`; pane switching in
  `DaemonWorkflowWindowController+Navigation.swift` (`showContentPane`, `showSourcesPane`,
  `updateSidebarSelection`).
- `Sources/RielaApp/DaemonWorkflowWindowController.swift:308` — `update(...)` pushes fresh
  state from the app delegate into the controller; the delegate wires ~30 closures into the
  controller initializer (`Sources/RielaApp/EntryPoint.swift:144`).
- Workflow metadata: a bundle's `workflow.json` carries `workflowId` and optional
  `description` (`Sources/RielaCore/WorkflowModel.swift:518`, `AuthoredWorkflowJSON`).
  Package manifests (`riela-package.json`, `Sources/RielaAddons/WorkflowPackageManifest.swift`)
  carry `name`, `title`, `description`, and per-workflow `title`/`description`.

## Non-Goals

- No changes to the CLI package-registry mechanism (`riela package registry ...`); the app
  feature is intentionally independent and simpler (a repository is just "a GitHub repo that
  contains workflow bundles"), matching the existing app import model.
- No GitHub API usage, authentication, or private-repository support. Fetching uses `git`
  over HTTPS exactly like the existing materializer, so only public repositories work.
- No version/update management (install always copies the currently fetched content;
  re-install overwrites, reusing existing replace semantics).
- No Linux/unsupported-platform UI.

## Design

### 1. Registered repositories (model + persistence)

New value type in `RielaAppSupport`
(`Sources/RielaAppSupport/RielaAppWorkflowRepositoryReference.swift`):

```swift
public struct RielaAppWorkflowRepositoryReference: Codable, Equatable, Sendable {
  public var owner: String
  public var repository: String
  public var branch: String?          // nil → remote default branch

  public var id: String               // "owner/repository" or "owner/repository@branch"
  public var cloneURL: String         // "https://github.com/owner/repository.git"
  public var webURL: String           // "https://github.com/owner/repository"

  public static func parse(_ rawValue: String) throws -> RielaAppWorkflowRepositoryReference
}
```

`parse` accepts:

- `https://github.com/<owner>/<repo>` (optionally with trailing `.git` or `/`)
- `https://github.com/<owner>/<repo>/tree/<branch>` (branch pinned; deeper paths rejected)
- `<owner>/<repo>` shorthand

Components are validated with the same character rules as
`RielaAppGitHubSourceMaterializer.isSafeComponent` (letters, digits, `-`, `_`, `.`; never
`.`/`..`). Anything else throws a typed error
(`RielaAppWorkflowRepositoryReferenceError.unsupported/unsafe`).

Persistence: `RielaAppDaemonWorkflowState` gains
`workflowRepositories: [RielaAppWorkflowRepositoryReference]` (new CodingKey, decoded with
`decodeIfPresent ?? []`), plus `containsWorkflowRepository(_:)`,
`addWorkflowRepository(_:)`, `removeWorkflowRepository(id:)` mutators (sorted by `id`,
duplicates by `id` ignored). Repositories are therefore **per profile**, consistent with
every other source registration in the app.

### 2. Catalog fetch + scan (service layer)

New file `Sources/RielaAppSupport/RielaAppWorkflowRepositoryCatalog.swift`:

```swift
public struct RielaAppRemoteWorkflowListing: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case workflowDirectory        // standalone bundle: directory with workflow.json
    case packageWorkflow          // workflow.json living inside a riela package
  }
  public var repositoryId: String
  public var workflowId: String
  public var title: String              // package workflow title ?? workflowId
  public var summary: String            // description (workflow.json > package manifest > "")
  public var relativePath: String       // repo-relative path of the *installable* directory
  public var installSourceURL: URL      // local checkout dir to hand to the installer
  public var kind: Kind
  public var packageName: String?       // set for .packageWorkflow
}

public struct RielaAppWorkflowRepositoryCatalog: Equatable, Sendable {
  public var repository: RielaAppWorkflowRepositoryReference
  public var workflows: [RielaAppRemoteWorkflowListing]
}
```

Scanner `RielaAppWorkflowRepositoryCatalogScanner.scan(repositoryRoot:repositoryId:)`:

- Walks the checkout (skips `.git`, hidden dirs, symlinks; bounded depth 8) looking for
  directories containing `workflow.json`.
- For each hit, decodes a minimal `{workflowId, description}`; invalid/undecodable bundles
  are skipped (never abort the whole scan).
- If an ancestor directory contains `riela-package.json`, the listing becomes
  `.packageWorkflow`: `installSourceURL`/`relativePath` point at the **package root** (so
  Install preserves skills/addons/env metadata via the existing package installer), and
  title/description fall back to the manifest's per-workflow `title`/`description`, then the
  package `title`/`description`. Manifest decoding uses a minimal local `Decodable` (name,
  title, description, workflows[].title/description) so scanning never depends on full
  manifest validity.
- Results are de-duplicated by `relativePath + workflowId` and sorted by `title`.

Fetcher `RielaAppWorkflowRepositoryCatalogLoader`:

```swift
public struct RielaAppWorkflowRepositoryCatalogLoader: Sendable {
  public var cacheRoot: URL      // default: <appRootURL>/marketplace-cache
  public var gitExecutable: String = "git"

  public func loadCatalog(
    for repository: RielaAppWorkflowRepositoryReference,
    forceRefresh: Bool
  ) throws -> RielaAppWorkflowRepositoryCatalog
}
```

- Checkout dir: `<cacheRoot>/<sanitized id>` (sanitized with
  `RielaAppManagedWorkflowInstaller.sanitizedDirectoryName` semantics).
- `forceRefresh` (or missing/broken cache) deletes the directory and runs
  `git clone --depth 1 [--branch <branch>] <cloneURL> <dir>` via the same
  `/usr/bin/env git` + stderr-capture pattern as `RielaAppGitHubSourceMaterializer.runGit`.
  A full (non-sparse) shallow clone is used because listing requires scanning the whole
  tree; workflow repositories are small by construction.
- The cache is kept on disk after scanning so a subsequent Install can copy from it without
  re-cloning. `cacheRoot` lives under the app root (not per profile): repository content is
  profile independent.
- Errors are typed (`RielaAppWorkflowRepositoryCatalogError.gitFailed/missingCheckout`) and
  surfaced per repository in the UI without failing other repositories.

### 3. App delegate integration

New file `Sources/RielaApp/EntryPoint+WorkflowMarketplace.swift` (extension on `RielaApp`):

- New delegate state:
  `var marketplaceCatalogs: [String: RielaAppWorkflowRepositoryCatalog]`,
  `var marketplaceErrors: [String: String]`,
  `var marketplaceRefreshingRepositoryIds: Set<String>`.
- `addWorkflowRepository(rawValue:)` — parse; reject duplicates with a status message;
  append to `daemonState.workflowRepositories`; `saveDaemonState()` (rollback on failure,
  same pattern as imports); trigger a fetch of the new repository.
- `removeWorkflowRepository(id:)` — remove from state, save, drop cached catalog/error,
  refresh window. Installed workflows are untouched (removal only unregisters the source,
  matching VSCode semantics of removing a source, not uninstalling).
- `refreshWorkflowRepositoryCatalogs(forceRefresh:)` — for each registered repository not
  already refreshing: mark refreshing, run `loadCatalog` inside `Task.detached`, publish the
  result (`catalog` or `error`) back on the main actor, `refreshDaemonWorkflowWindow()`.
- `installMarketplaceWorkflow(repositoryId:relativePath:)` — resolve the listing from the
  cached catalog, verify `installSourceURL` still exists (else prompt to refresh), then call
  the existing `importDaemonWorkflowOrPackageSourcesOnly([installSourceURL])`
  (`EntryPoint.swift:628`), which validates, copies into the profile root, updates
  preferences, saves state, and refreshes the window. No new install code paths.

All four handlers are exposed to the window controller as new injected closures
(`onAddWorkflowRepository`, `onRemoveWorkflowRepository`, `onRefreshWorkflowRepositories`,
`onInstallMarketplaceWorkflow`), added to the initializer with default no-op values so
existing constructions (tests) keep compiling.

### 4. UI: Marketplace pane

New sidebar entry **Marketplace** (`SidebarPane.marketplace`, SF Symbol
`square.and.arrow.down`), placed between "Workflow Sources" and "Assistant":

- `DaemonWorkflowWindowController+SettingsShell.swift` — add `sidebarMarketplaceButton` to
  the menu stack.
- `DaemonWorkflowWindowController+Navigation.swift` — `showMarketplacePane()`, back-button
  and selection handling, and `marketplaceOverviewView` participation in `showContentPane`.

New file `Sources/RielaApp/DaemonWorkflowWindowController+MarketplacePane.swift`, mirroring
the Sources pane structure (`buildSourcesOverviewView` / fingerprint-based rebuild):

- **Header**: summary label ("N repositories, M workflows"), spacer, `Add Repository`
  button (prompts for a repository URL with an explanatory message), `Refresh` button.
- **Body**: one settings section per registered repository:
  - Section caption: repository `id` (+ branch), with a small `Remove` action.
  - While fetching: a "Loading…" row; on error: the error message row with a Retry action.
  - One row per workflow listing: title (medium 14pt), description + metadata
    (secondary 11pt, `rielaAppMetadataText([summary, kind, workflowId])`), spacer, and an
    **Install** `NSButton` on the trailing edge.
  - Install button states derived on rebuild: `Install` (enabled) when the `workflowId` is
    not among the current profile's `workflowSources`; `Installed` (disabled) when it is;
    `Reinstall` is intentionally not offered (matches goal scope).
  - The button's `identifier` encodes `repositoryId` + unit separator + `relativePath`; the
    `@objc` action decodes it and calls `onInstallMarketplaceWorkflow`.
- **Empty state**: "No repositories registered. Add a GitHub repository that contains riela
  workflows to browse and install them."
- Data flow: `update(...)` gains defaulted parameters
  `marketplaceRepositories: [RielaAppWorkflowRepositoryReference] = []`,
  `marketplaceCatalogs: [String: RielaAppWorkflowRepositoryCatalog] = [:]`,
  `marketplaceErrors: [String: String] = [:]`,
  `marketplaceRefreshingRepositoryIds: Set<String> = []`, stored on the controller and
  folded into a marketplace fingerprint so the pane only rebuilds on change.
- Opening the pane triggers a lazy initial fetch (via `onRefreshWorkflowRepositories`) when
  a registered repository has no cached catalog, error, or in-flight refresh.

### 5. Security / safety considerations

- Only `https://github.com/<owner>/<repo>` (public) shapes are accepted; component
  validation reuses the existing safe-character rules, preventing argument injection into
  `git` and path traversal in cache directory names.
- Clones are shallow (`--depth 1`) and land only under the app-owned cache root.
- Scanning ignores symlinks so a hostile repository cannot make listings point outside its
  own checkout.
- Installation reuses the existing installers, which already enforce destination
  containment inside the profile root (`RielaAppManagedWorkflowInstaller.swift:59,141`) and
  full package-manifest validation for packages.

## Acceptance Criteria

1. A user can register `https://github.com/tacogips/riela-packages` (or any public repo
   containing workflow bundles) from the Marketplace pane; the registration survives app
   restarts and is scoped to the active profile.
2. The pane lists every workflow bundle in the registered repositories with its name and
   description (from `workflow.json`, falling back to package manifest metadata).
3. Pressing **Install** on a row installs the workflow (or its containing package) into the
   active profile; it then appears under Workflow Sources, and the row shows a disabled
   **Installed** button.
4. Fetch failures (bad URL, no network, missing branch) surface as per-repository error
   rows without breaking other repositories, and legacy `daemon-workflows.json` files
   without the new field keep loading.
