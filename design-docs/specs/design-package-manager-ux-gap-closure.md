# Package Manager UX Gap Closure

Feature-local design for closing verified gaps between the accepted package
design slices and the Swift production `riela package` command surface, so the
documented end-user journey — search a registry, install a package and its
dependencies, keep it updated — works without a pre-arranged local checkout or
manual dependency management.

## Overview

A 2026-07-06 end-user audit of the `tacogips/riela-packages` registry against
riela 0.1.17 (Homebrew) reproduced the following behavior with the shipped
CLI:

- `riela package search goal` returns `no packages found` in any directory,
  including a full registry checkout, unless the caller either passes
  `--local-path` or happens to keep the checkout at the undocumented default
  `<working-directory>-packages` sibling path
  (`defaultRegistryEntry` in `Sources/RielaCLI/WorkflowPackageParityCommands.swift`).
  The default registry is never cloned or fetched by the CLI.
- `riela package install cursor-cli-developer-workflows` (a meta package with
  12 `dependencies`) installs exactly one package. Declared dependencies are
  validated as metadata and never resolved, even though
  `design-workflow-package-registry.md` §"Issue 43 Dependency Install
  Contract" fully specifies a dependency-aware install transaction.
- `riela package search` matches package `name` and `tags` substrings only.
  `design-workflow-package-registry.md` §"Baseline matching" requires name,
  title, description, tags, backends, and workflow ids, and
  `design-workflow-package-commands.md` §"Search And Metadata Commands"
  requires `--tag`, `--backend`, `--limit`, `--refresh`, and table output.
- `riela package update <id>` only checks that the package exists locally and
  reports `package update checked <id>`. No design slice currently specifies
  update semantics.
- Subcommands reject `--help` with `unknown option '--help'`, so the only
  discoverable usage documentation is external.
- `environmentVariables` entries in `riela-package.json` are surfaced by
  RielaApp but not by CLI install/status output, so terminal users learn about
  required credentials (for example the Google Speech-to-Text one-of
  credential set) only at workflow runtime.

This document treats the Issue 43 contract, the registry cache/refresh
contract, and the search matching contract as accepted upstream designs and
specifies only what the Swift runtime must add or change to honor them, plus
the genuinely new slices: managed registry acquisition, `package update`
semantics, subcommand help, and CLI environment-variable surfacing.

## Feature Contract

- Feature ID: `package-manager-ux-gap-closure`
- Depends on: `design-workflow-package-registry.md` (registry metadata, cache,
  Issue 43 dependency install contract, baseline search matching),
  `design-workflow-package-commands.md` (command surface, output contracts),
  `design-workflow-package-checkout.md` (checkout staging and provenance).
- Supersedes nothing; it narrows implementation debt against those designs.
- Non-goals: package publish flows, registry policy defaults, signature-gate
  changes, RielaApp UI changes, and any weakening of md5/sha256/Ed25519 gates.

## G1: Dependency-Aware Install

Implement the Issue 43 dependency install transaction in the Swift install
path (`WorkflowPackageCommandRunner+Install.swift`), exactly as specified in
`design-workflow-package-registry.md`:

1. Resolve and validate the caller manifest with normalized dependency
   entries.
2. Recursively resolve dependency manifests depth-first before caller workflow
   validation, with cycle detection on normalized package identity reporting
   the chain (`a -> b -> c -> a`).
3. Treat equivalent already-installed dependencies (same normalized identity,
   scope, and loadable destination workflow) as satisfied without
   `--overwrite`.
4. Run the full install gate set for missing dependencies; validate the caller
   only after all dependencies are visible in the destination catalog.
5. Roll back only the artifacts newly created by the failing transaction.

Swift-surface additions:

- `--no-dependencies` opts out and restores current single-package behavior
  for maintainers validating a package in isolation (the registry `Taskfile`
  dry-run flow).
- Dry-run output lists the dependency resolution plan (`wouldInstall`,
  `satisfied`, `missing`) without mutating anything.
- Install JSON adds `dependencies[]` records mirroring the per-package install
  records, so automation can report what a meta package actually pulled in.
- When a dependency cannot be resolved from the selected registry, the error
  names the dependency id, the caller chain, and the registry/local path that
  was searched.

## G2: Registry Acquisition And Default Local Path

Today the default registry entry points at the `<working-directory>-packages`
sibling path, which exists for the development checkout convention
(`design-workflow-package-registry.md` overview) but silently yields empty
search results for end users.

Design:

- Add a managed registry cache root at `~/.riela/registries/<registry-id>`
  used when a registry has no explicit `localPath`. `riela package search
  --refresh` and a new `riela package registry sync [<registry-id>]` clone or
  fast-forward the registry's configured branch into that root using `git`.
  Network access happens only on `--refresh`, `registry sync`, or a
  first-use cache miss that the command explicitly reports before fetching;
  `package list` stays offline per the commands design.
- Resolution order for a registry's content root: explicit `--local-path`
  flag, configured `localPath`, existing `<working-directory>-packages`
  sibling (kept for development compatibility), then the managed cache root.
- When every candidate is missing, the error must name each candidate path and
  the sync command instead of returning a bare `no packages found`. Empty
  search results over an existing root must state which root was searched.
- Registry config persistence stays under `~/.riela` as designed; the managed
  cache is disposable and re-creatable from the registry URL.

## G3: Search Matching Parity

Bring `riela package search` up to the accepted baseline:

- Match query text against package name, title, description, tags, backends,
  and workflow ids (case-insensitive substring at minimum; ranking may stay
  trivial in this slice).
- Add `--tag` and `--backend` exact-match filters (normalized), `--limit`, and
  `--refresh`.
- Add `--output table` with the designed columns `PACKAGE`, `WORKFLOW`,
  `REGISTRY`, `TAGS`, `SUMMARY`; JSON output adds match metadata and cache
  metadata fields.

## G4: Real `package update`

`design-workflow-package-commands.md` references update decisions but never
specifies the command. Semantics for this slice:

- `riela package update <selector>` resolves installed package checkout
  records with the same selector rules as `package status`.
- For each selected record, re-resolve the package from its recorded registry
  (`registryUrl`, `registryRef`) or `--local-path` override, compare
  `packageVersion`, `checksum`, and `integrityDigest`.
- Unchanged packages report `upToDate: true` and mutate nothing.
- Changed packages reinstall through the G1 install transaction (including
  dependency resolution) with implicit overwrite of the package-owned
  destination; `--yes` bypasses the confirmation, matching install behavior.
- `--all` updates every package checkout record in the requested scope.
- `--dry-run` reports `wouldUpdate` / `upToDate` per package without mutation.
- JSON output extends install records with `previousVersion`,
  `previousChecksum`, and `updateState` (`up-to-date`, `updated`,
  `failed`).

The current stub response (`package update checked <id>`) is removed; scripts
depending on it must switch to `package status`.

## G5: Subcommand Help

`riela package <subcommand> --help` (and bare `riela package --help`) must
print usage for that subcommand instead of `unknown option '--help'`:

- one-line summary, argument synopsis, and the supported options with the
  same names the parser accepts (`--local-path`, `--scope`, `--overwrite`,
  `--dry-run`, `--output`, and the new flags from G1-G4)
- exit code 0, output on stdout, honored for every `package` subcommand

This slice does not attempt a general help framework for all command families;
it covers the `package` family and leaves broader help routing to the parity
plan.

## G6: Environment Variable Surfacing

CLI parity with the RielaApp behavior that filters `environmentVariables`
with `required: true`:

- `package install` (including dry-run) and `package status` output include a
  `requiredEnvironment` array of `{name, description, required, secret}` from
  the installed manifest, with secret values never echoed (names only).
- Text output prints a short `environment:` section after install when the
  manifest declares any environment variables, so one-of credential sets like
  `GOOGLE_ACCESS_TOKEN` / `GOOGLE_APPLICATION_CREDENTIALS` /
  `GOOGLE_APPLICATION_CREDENTIALS_JSON` are visible before first run.

## Decisions

- Dependency installation defaults to ON for `package install`; isolation
  validation uses `--no-dependencies`. The registry maintainer `Taskfile`
  should adopt the flag when this ships.
- The `<working-directory>-packages` sibling default stays recognized for
  development compatibility but is demoted to a fallback candidate and must be
  named in error output when consulted.
- `package update` reinstalls rather than patching in place; checkout staging
  and rollback already exist for install and are reused.
- Flag naming: this slice keeps the shipped `--scope user` spelling and adds
  nothing new; reconciling `--scope user` versus the commands design's
  `--user-scope` remains with the parity plan (see Open Questions).

## Open Questions

- Should `--user-scope` from `design-workflow-package-commands.md` be added as
  an alias of `--scope user`, or should the commands design be amended to the
  shipped spelling?
- Should first-use cache miss auto-fetch require an interactive confirmation
  in TTY contexts, or is the explicit pre-fetch report sufficient?
- Does `registry sync` need shallow-clone/depth controls for large registries,
  or is a full clone acceptable for the default registry's size?

## Risks

- Dependency-aware install changes the observable behavior of existing
  automation that installs meta packages and expects a single record;
  mitigated by the additive `dependencies[]` JSON field and `--no-dependencies`.
- Git-based registry sync introduces a network and `git`-binary dependency
  into search/install paths that were previously offline-only; mitigated by
  fetching only on `--refresh`, `registry sync`, or reported first-use miss.
- Update-as-reinstall can delete user-modified files inside package-owned
  destinations; mitigated by the existing package-ownership checks, the
  confirmation gate, and `--dry-run`.

## Verification

- Unit tests in `Tests/RielaCLITests` covering: dependency resolution order,
  cycle detection message, equivalent-dependency satisfaction, transaction
  rollback, update state transitions, search matching fields and filters,
  subcommand help output, and requiredEnvironment projection.
- Fixture-based lifecycle test: install `cursor-cli-developer-workflows` from
  a local registry fixture and assert 13 package records; re-run and assert
  all dependencies satisfied; `package update --all --dry-run` reports
  `upToDate` for every record.
- Manual verification against a `tacogips/riela-packages` checkout:
  `package search goal` finds the three goal packages with no flags after
  `registry sync`, and `package search --refresh` succeeds from an empty
  cache.

## References

- `design-docs/specs/design-workflow-package-registry.md`
- `design-docs/specs/design-workflow-package-commands.md`
- `design-docs/specs/design-workflow-package-checkout.md`
- `Sources/RielaCLI/WorkflowPackageParityCommands.swift`
- `Sources/RielaCLI/WorkflowPackageCommandRunner+Install.swift`
- `Sources/RielaCLI/WorkflowPackageCommandRunner+Archives.swift`
- `Sources/RielaAddons/WorkflowPackageManifest.swift`
- `Sources/RielaAddons/WorkflowPackageManifestModels.swift`
- 2026-07-06 riela-packages registry audit (README install-journey rewrite in
  `tacogips/riela-packages`)
