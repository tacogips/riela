# Distributed Registry And Container Node Roadmap

Feature-local design for evolving Riela package distribution and executable
node reuse without introducing a bespoke npm-style registry service.

## Overview

Riela already has most of the model surface needed for package discovery,
dependency install, and executable add-ons:

- package search can consume `registry-index.json` metadata from a managed
  GitHub registry cache;
- package install already resolves declared dependencies in the Swift runtime;
- add-on manifests already support `execution.kind: "container"` and
  `containerfilePath`;
- add-on capabilities already model permissions such as `network.egress` and
  `filesystem.write`;
- `riela doctor` can inspect installed package manifests and local runtime
  prerequisites.

The missing work is therefore not a new registry product. The path is to fill
the remaining distribution and runtime gaps while preserving the current
GitHub repository registry shape.

## Feature Contract

- Feature ID: `distributed-registry-container-node-roadmap`
- Depends on: `design-package-manager-ux-gap-closure.md`,
  `design-workflow-package-registry.md`,
  `design-workflow-package-commands.md`,
  `design-workflow-package-checkout.md`,
  `Sources/RielaAddons/WorkflowPackageManifest.swift`,
  `Sources/RielaCLI/WorkflowPackageParityCommands.swift`,
  `Sources/RielaCLI/DoctorCommand.swift`.
- Non-goals: hosted registry server operation, public package publishing
  governance, bypassing package checksum/integrity validation, or weakening
  add-on capability review.

## G1: Indexed GitHub Registry

Keep registries as GitHub repositories, but make search and install avoid a
full clone when metadata is enough.

- CI in the registry repository generates a deterministic `registry-index.json`
  from package manifests.
- CLI search fetches the index for discovery and only materializes package
  content when install, validate, pack, or update requires source files.
- Index records include package id, directory, version, kind, title,
  description, tags, workflow ids, backends, execution kind, runtime hints,
  capability names, required environment variable names, checksum, and
  integrity digest.
- Registry sync remains explicit through `package search --refresh`,
  `package registry sync`, or reported first-use cache miss.

This keeps Phase 1 compatible with the existing distributed registry design and
directly reduces the current pain of needing a local checkout before search.

## G2: Archive And Lock Distribution

After index-only discovery works, add pinned archive install semantics.

- CI attaches `.rielapkg` artifacts to GitHub Releases and writes each archive
  sha256 into the registry index.
- `riela-lock.json` records package id, version, registry URL, registry ref,
  archive URL, archive sha256, integrity digest, and resolved dependencies.
- `riela package install --locked` behaves like `npm ci`: it installs exactly
  the lockfile graph and fails on missing or mismatched archive digests.
- Unlocked install updates the lockfile only after every package and dependency
  passes the existing validation and ownership gates.

The registry remains static files plus release assets; no separate registry
server is introduced.

## G3: Container Node Runtime

Implement `execution.kind: "container"` as an enforced executable add-on
runtime.

- CI builds multi-architecture OCI images for container add-ons and pushes
  them to `ghcr.io`.
- Package metadata records the resolved image digest. Tags are allowed for
  authoring convenience but execution uses digests.
- `ContainerRuntime` is an internal abstraction with drivers for Apple
  Container, Docker, and Podman. Driver selection is deterministic:
  configured driver, Apple Container on supported macOS when available, then
  Docker, then Podman.
- Capability declarations are mapped to runtime enforcement where practical:
  filesystem grants become mounted paths, network-denied add-ons run without
  egress when supported by the driver, and undeclared writes are blocked.
- Local builds from `containerfilePath` are development-only; installed
  registry packages use prebuilt images by digest so non-engineers do not need
  `yt-dlp`, `ffmpeg`, or build tools on the host.

## G4: Container Setup And Doctor Guidance

Container-required packages should guide users before runtime failure.

- `riela doctor` reports installed container add-ons, available container
  runtimes, and missing container runtime requirements.
- `riela setup container` downloads the signed Apple Container installer
  package on macOS, installs it through the standard macOS installer path, and
  starts the service with `container system start`.
- When a workflow requires a container add-on and no supported runtime exists,
  CLI and app flows prompt the user toward the setup command before execution.
- The setup command must remain idempotent and must never collect credentials.

As of 2026-07-07, the official Apple `container` README says the tool is for
Apple silicon, is supported on macOS 26, is installed from a signed package on
the GitHub releases page, and requires `container system start` after install.

## G5: Node-Level Reuse And Single-Node Run

Reduce duplicated node implementations between projects.

- Shared add-on content is stored under
  `~/.riela/addons/<namespace>/<name>/<version>`, with legacy reads from
  `~/.riela/content-ad/addons/<namespace>/<name>/<version>` for compatibility.
- Workflow manifests can reference package add-ons without copying the same
  worker files into every workflow directory.
- Add a user-facing single-node runner, `riela node run`, plus `rrun` as a
  short alias, for running an add-on without hand-authoring a workflow.
- Single-node run accepts JSON variables, environment validation, and the same
  capability/runtime preflight as workflow execution.

## Decisions

- Do not build an npm-compatible registry protocol or a new hosted registry
  service in this phase. GitHub index files, release artifacts, and OCI images
  are sufficient and operationally simpler.
- Container execution must enforce capabilities instead of only documenting
  them. `local-command` remains a compatibility/runtime-hint path; container
  add-ons are the secure execution target.
- Prebuilt image digest execution is the default for installed packages.
  `containerfilePath` remains the source-of-truth for CI builds and local
  package development.
- Apple Container is the preferred macOS non-engineer path when supported, but
  Docker and Podman remain valid runtime drivers.

## Open Questions

- Should the registry index include every lockfile dependency edge, or should
  dependency graph expansion stay with per-package manifest fetches until G2?
- Should `riela setup container` support Homebrew cask install as an opt-in
  fallback, or only the signed package path?
- How should driver-specific network egress restrictions be represented when a
  runtime cannot enforce a requested deny policy?
- Should `rrun` be a separate installed executable or only a shell alias/helper
  printed by setup?

## Verification

- Registry CI test regenerates `registry-index.json` from fixtures and proves
  byte-for-byte deterministic output.
- CLI test searches an index-only registry and installs from archive URLs with
  sha256 verification.
- Lockfile tests cover clean install, digest mismatch failure, dependency graph
  changes, and no-mutation failure behavior.
- Container runtime tests use fake Apple Container/Docker/Podman drivers to
  verify driver selection, digest invocation, mount policy, network policy, and
  failure diagnostics.
- Doctor tests cover container-required add-ons with and without an available
  runtime.
- Manual macOS verification covers Apple Container installation, service start,
  `doctor` readiness, and a YouTube download add-on using prebuilt
  `yt-dlp`/`ffmpeg` image content without host installs.

## References

- Apple Container README: `https://github.com/apple/container`
- Apple Containerization README: `https://github.com/apple/containerization`
- `design-docs/specs/design-package-manager-ux-gap-closure.md`
- `impl-plans/active/package-manager-ux-gap-closure.md`
