# Distributed Registry And Container Node Roadmap Implementation Plan

**Status**: Implemented foundation; release publication pending external CI.
**Remaining items are explicitly accepted external deferrals** (2026-07-12):
release publication and cask update require external CI/release credentials —
owner: repository maintainer with release access; trigger: next release
window (ship a Homebrew cask newer than 0.1.17 so distributed binaries include
live cross-workflow dispatch). No further local engineering work is open in
this plan.
**Design Reference**:
`design-docs/specs/design-distributed-registry-container-node-roadmap.md`
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

## Summary

Build on the implemented package-manager UX closure by adding the next
distribution/runtime layers: deterministic registry indexes, archive and
lockfile installs, enforced container add-on execution, container setup/doctor
guidance, and single-node reuse commands.

## Scope

Included: registry index generation/consumption, `.rielapkg` archive pinning,
`riela-lock.json`, `ContainerRuntime` driver abstraction, Apple
Container/Docker/Podman detection, `riela doctor` container requirement
diagnostics, `riela setup container`, shared add-on content layout, and
`riela node run`/`rrun` command design.

Excluded: hosted registry service, public moderation/publish policy,
credential storage, and broad RielaApp UI flows beyond readiness prompts.

## Modules

### 1. Registry Index Generator

**Status**: Implemented foundation

- [x] Add reusable index generation code that scans package manifests and
      emits deterministic `registry-index.json`.
- [x] Include execution kind, runtime hints, capabilities, required
      environment, checksum, and integrity metadata.
- [x] Add fixture tests proving stable sort order and byte-for-byte output.
- [x] Add a registry CI invocation path suitable for `tacogips/riela-packages`.

### 2. Archive Install And Lockfile

**Status**: Implemented foundation

- [x] Extend package install/update to resolve archive URLs and sha256 from
      index records.
- [x] Add `riela-lock.json` read/write models for installed packages.
- [x] Ensure rollback leaves the prior lockfile intact on failure.
- [x] Add `riela package install --locked` validation semantics.
- [x] Cover dependency graph changes and digest mismatch tests.

### 3. Container Runtime Execution

**Status**: Implemented foundation

- [x] Add `ContainerRuntime` protocol and Apple Container, Docker, and Podman
      drivers.
- [x] Add driver discovery and deterministic selection policy.
- [x] Add manifest metadata for prebuilt container images and image digests.
- [x] Execute container add-ons by image digest for installed packages.
- [x] Keep local `containerfilePath` builds as a development fallback.
- [x] Map add-on capabilities to mounts, environment, and network policy.
- [x] Add one manual local runtime smoke path.

### 4. Doctor Container Readiness

**Status**: Implemented foundation

- [x] Report installed container add-ons in `riela doctor`.
- [x] Mark container requirements missing when no supported runtime is on
      `PATH`.
- [x] Include container runtime counts in the doctor summary.
- [x] Replace provisional setup hint with the final `riela setup container`
      command once that command exists.
- [x] Surface the same preflight in workflow execution before a container
      add-on runs.

### 5. Container Setup Command

**Status**: Implemented foundation

- [x] Add `riela setup container` parser and help text.
- [x] Download the signed Apple Container installer package from the selected
      release channel.
- [x] Invoke the macOS installer path and run `container system start`.
- [x] Make the command idempotent and add dry-run diagnostics.
- [x] Add tests around command planning; keep actual installer invocation as a
      manual verification step.

### 6. Node-Level Reuse

**Status**: Implemented foundation

- [x] Project node-addon installs project add-on content into a shared add-on
      store under `.riela/addons/<namespace>/<name>/<version>`.
- [x] Resolve container add-on references from installed project packages and
      the shared add-on store.
- [x] Add `riela node search`, `riela node list`, `riela node install`, and
      `riela node run` command behavior.
- [x] Align the shared-store path with the final
      `.riela/addons/<namespace>/<name>/<version>` naming while retaining
      `.riela/content-ad/addons/...` as a legacy read fallback.
- [x] Add the `rrun` short entry point.
- [x] Reuse package environment validation and runtime/capability preflight
      for every non-mock single-node execution path.

## Progress Log

### Session: 2026-07-07

**Tasks Completed**: Added the roadmap design document. Added `riela doctor`
container requirement reporting and tests for missing/runtime-available
container add-ons. Added `riela package registry index <registry-root>` with
deterministic `registry-index.json` generation from package manifests,
including add-on execution kind, runtime hints, capabilities, required
environment, dependencies, checksum, and integrity metadata. Added prebuilt
container image metadata (`execution.image` and `execution.imageDigest`) to
package manifests, registry index output, installed add-on registration, doctor
output, and container add-on execution so digest-pinned images skip local
builds while `containerfilePath` remains a development fallback. Added typed
container runtime drivers for Apple Container, Docker, Podman, and explicit
custom commands, with deterministic discovery via `RIELA_CONTAINER_RUNTIME`
or `PATH` preference order (`container`, `docker`, `podman`). Added
execution-time missing-runtime preflight before container add-ons spawn local
processes. Added a `riela setup container` foundation command with JSON/text
planning output, dry-run/script support, existing-runtime detection, and
`container system start` execution when `--yes` is used with an installed
Apple Container runtime.
Extended `riela setup container --yes` so the missing-runtime path resolves the
latest Apple Container GitHub release `.pkg`, downloads it to a temporary
installer path, invokes `/usr/sbin/installer -pkg ... -target /`, and then
starts `/usr/local/bin/container system start`; the implementation is covered
with injected release/downloader/process fakes. Verified the node-level reuse
foundation: `riela node install` projects add-on packages into the shared
add-on store, `riela node search`/`riela node list` discover node add-ons,
`riela node run` executes a single add-on without a workflow, and container
add-on resolution reads both project packages and the shared add-on store.
Added container sandbox policy mapping from add-on capabilities: declared
`filesystem.read` scopes become read-only bind mounts, declared
`filesystem.write` scopes become read-write bind mounts, undeclared absolute
input paths fail before process spawn, `env.read` scopes select which host
environment variables pass through, root filesystems run read-only with
temporary storage, and add-ons without `network.egress` are invoked with
networking disabled where the selected runtime supports it.
Added `riela package registry index <registry-root> --check` for CI: it
regenerates the deterministic index in memory, exits successfully when the
checked-in destination is current, fails when `registry-index.json` is stale or
missing, and never rewrites the destination in check mode.
Aligned node-level reuse storage with the final shared add-on store contract:
`riela node install` projects add-on content under
`.riela/addons/<namespace>/<name>/<version>`, while installed container add-on
discovery still reads legacy `.riela/content-ad/addons/...` entries for
compatibility.
Added `rrun <addon-name>` as a top-level alias for `riela node run
<addon-name>`, preserving the same node command scope, structured result, and
mock-scenario execution path.
Added Phase 2 archive foundations: generated registry indexes now include
release archive URLs and optional archive sha256 values, install/update can
resolve index-only package records to pinned `.rielapkg` archives, archive
downloads fail closed on sha256 mismatch before extraction, and registry
archive lockfile entries retain the original archive URL while recording the
verified archive digest.
Added `riela package install --locked` as the lockfile replay path alongside
`riela package ci`; locked installs now verify locked archive digests, replay
source/archive package graphs from `riela-lock.json`, and keep prior lockfile
state intact on archive digest failure.
Aligned the npm-style lockfile UX further: `riela package install` with no
target and no `--source` now replays `riela-lock.json`, matching
`riela package ci` / `riela package install --locked` while preserving
`package install --source <dir>` for direct package installs.
Added non-mock `riela node run`/`rrun` preflight against installed/shared
node-addon package metadata: package-required environment variables, host
runtime hints, and container runtime availability now fail before a single-node
execution starts, while mock-scenario runs remain deterministic and skip host
preflight.
Aligned the shared add-on store documentation and tests with the final
`~/.riela/addons/<namespace>/<name>/<version>` path; legacy
`~/.riela/content-ad/addons/...` entries remain readable for compatibility.
Manually smoke-tested the packaged `pdf-to-images` container add-on with Docker:
the Containerfile built successfully, a sample PDF was rendered inside a
read-only container, and the PNG artifact was written through the
`RIELA_ARTIFACT_DIR` mount.
Extended `riela doctor` beyond executable discovery for container runtimes:
installed Apple Container CLIs are checked with `container system status
--format json`, Docker and Podman CLIs are checked with `info`, stopped or
unregistered services are reported as warning, and container add-on
requirements remain missing until a runnable container runtime is available.
Added doctor tests for required environment variables, runtime hints, missing
runtimes, available runtimes, installed-but-stopped Apple Container, and Docker
daemon readiness.
Tightened the non-engineer Apple Container setup path: `riela setup container
--open-installer` now resolves the latest signed `.pkg`, downloads it, verifies
it with `spctl --assess --type install`, and opens the downloaded package
directly in the macOS installer UI. `riela setup container --yes` now runs the
same signature verification before invoking `/usr/sbin/installer`; verification
failure stops before open/install.
Replaced the provisional `riela setup container --print-script` placeholder
commands with an executable shell script: it resolves the latest `.pkg` from
the GitHub release API, downloads it to a temporary directory, verifies the
installer with `spctl`, and either opens the signed package or runs
`sudo /usr/sbin/installer` followed by `container system start`.
Tightened container sandbox mapping for packaged PDF/image-analysis nodes:
`filesystem.read` with `scope: addon.input` now derives read-only mounts from
input payload path fields such as `pdfPath`, `filesystem.write` with
`scope: runtime.output` maps to `RIELA_ARTIFACT_DIR`, and container runs set
`-w` to the project working directory so relative PDF paths resolve inside the
container.
Made `containerfilePath` a real development fallback for unpublished images:
container add-ons only use `execution.image` directly when `imageDigest` is
present, while digest-less image references with a local `Containerfile` are
built locally. This keeps `pdf-to-images` usable before GHCR publication and
keeps published release paths digest-pinned.
Added release-readiness support in `riela-packages`: the container image
workflow now uploads per-package digest JSON artifacts for later
`execution.imageDigest` pinning, and `task package:check-release-publication`
regenerates local `.rielapkg` metadata then checks the fixed
`registry-packages` GitHub Release for every archive plus
`package-archives.json` and `registry-index.json`.
Published the `riela-packages` registry foundations to `main`, pushed the
`ghcr.io/tacogips/riela-packages/pdf-to-images-addon:0.1.0` image, pinned its
digest in the package manifest and registry index, and published the
`registry-packages` release assets. The package archive writer now produces
deterministic ZIP payloads and ignores generated Python cache files so local
release checks match clean GitHub Actions output. The default registry refresh
now downloads the fixed `registry-packages` release index for the default
`tacogips/riela-packages` registry, making fresh `package install --refresh`
resolve the published `.rielapkg` archive without cloning the registry.

**Tasks In Progress**: None.

**Blockers**: None.

**Verification**:

- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DoctorCommandTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowPackageRegistryIndexTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'ContainerWorkflowAddonResolverTests|WorkflowPackageManifestTests|WorkflowPackageRegistryIndexTests|DoctorCommandTests'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'SetupContainerCommandTests|ContainerWorkflowAddonResolverTests|DoctorCommandTests|WorkflowPackageRegistryIndexTests|WorkflowPackageManifestTests'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'SetupContainerCommandTests|ContainerWorkflowAddonResolverTests|DoctorCommandTests|WorkflowPackageRegistryIndexTests|WorkflowPackageManifestTests|NodeCommandTests'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ContainerWorkflowAddonResolverTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NodeCommandTests|ContainerWorkflowAddonResolverTests'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter testNodeSearchInstallAndRunProvideAddonLevelWorkflowlessEntryPoint`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'SetupContainerCommandTests|ContainerWorkflowAddonResolverTests|DoctorCommandTests|WorkflowPackageRegistryIndexTests|WorkflowPackageManifestTests|testNodeSearchInstallAndRunProvideAddonLevelWorkflowlessEntryPoint'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter testParsesRrunAsNodeRunAlias`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'CommandParsingTests|SetupContainerCommandTests|ContainerWorkflowAddonResolverTests|DoctorCommandTests|WorkflowPackageRegistryIndexTests|WorkflowPackageManifestTests|testNodeSearchInstallAndRunProvideAddonLevelWorkflowlessEntryPoint'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLITests`
- `tmp/index-archive-smoke-*` CLI smoke: `riela package init`, `pack`, index-only archive `install`, sha256 mismatch failure, and lockfile no-mutation check.
- `tmp/install-locked-smoke-*` CLI smoke: regular package install, deletion of installed package, `riela package install --locked`, and restored package output.
- `tmp/node-run-preflight-smoke` CLI smoke: node add-on install, mock-scenario `node run`, and non-mock missing environment preflight failure.
- `riela-packages` Docker smoke: `docker build -f packages/pdf-to-images-addon/addons/tacogips/pdf-to-images/1/Containerfile ...`; `docker run --read-only -e RIELA_ARTIFACT_DIR=/out ... /data/sample.pdf rendered 72 "" "" png` produced `out/addons/pdf-to-images/rendered/page-0001.png`.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DoctorCommandTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ContainerWorkflowAddonResolverTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DoctorCommandTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ContainerWorkflowAddonResolverTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'DoctorCommandTests|SetupContainerCommandTests|ContainerWorkflowAddonResolverTests|WorkflowPackageRegistryIndexTests|WorkflowCommandTests/testNodeSearchInstallAndRunProvideAddonLevelWorkflowlessEntryPoint|WorkflowCommandTests/testNodeInstallContainerAddonHintsSetupWhenRuntimeIsMissing|WorkflowCommandTests/testPackageInstallWritesProjectLockfileAndRemoveUpdatesIt|WorkflowCommandTests/testPackageInstallFromRielapkgPinsArchiveDigestInLockfile|WorkflowCommandTests/testPackageInstallFromIndexOnlyArchiveVerifiesDigestAndPinsReleaseURL'`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SetupContainerCommandTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'testPackageInstallWithoutTargetReplaysLockfileGraph|testPackageInstallLockedReplaysLockfileGraph|testPackageCIReplaysLockedSourceInstall|testPackageCIVerifiesLockedArchiveDigestBeforeInstall|testPackageInstallFromIndexOnlyArchiveVerifiesDigestAndPinsReleaseURL|testPackageInstallFromIndexOnlyArchiveDigestMismatchLeavesPriorLockfileIntact'`
- `riela node install tacogips/pdf-to-images --source packages/pdf-to-images-addon`
  followed by `riela node run tacogips/pdf-to-images --variables '{"pdfPath":"fixtures/report.pdf","outputDirectory":"rendered","dpi":72,"format":"png"}'`
  with `RIELA_CONTAINER_RUNTIME=docker` and an isolated `HOME`; produced
  `artifacts/addons/pdf-to-images/rendered/page-0001.png`.
- `riela-packages`: `ruby -e 'require "yaml"; ...'` parsed
  `.github/workflows/container-images.yml` and `package-archives.yml`.
- `riela-packages`: workflow hardening grep confirmed pinned `uses:` SHAs and
  no `github.event`/`github.head_ref`/`pull_request_target`/`secrets: inherit`
  / `write-all` patterns.
- `riela-packages`: digest-file dry run detected the expected
  `pdf-to-images-addon` `execution.imageDigest` update from a synthetic
  `container-image-digest-*` artifact payload.
- `riela-packages`: `check-release-publication.ts` correctly reports
  `release not found: tacogips/riela-packages@registry-packages` before the
  external release exists.
- `riela-packages`: pushed commits `65a4a3d`, `5146fd6`, `b21d8a3`,
  `24b5c79`, and `deac849` to `main`; `Package Archives` workflow runs
  `28811788977`, `28811963722`, `28812153450`, `28812265538`, and
  `28812375035` passed; `Container Images` workflow run `28811789026` passed.
- `riela-packages`: `task package:check-release-publication` passed against
  `tacogips/riela-packages@registry-packages`; downloaded
  `registry-index.json` and `package-archives.json` release assets matched
  local deterministic output byte-for-byte.
- `riela-packages`: `task package:check-digests package:check-index
  package:check-container-images` passed after digest pinning; GHCR digest
  lookup for `pdf-to-images-addon` reported `ok` and the published release
  index includes `imageDigest`
  `sha256:939b2d6fc3d0d4119dae3fe197f9f05a253a2d26b073714175710aa650cc577f`.
- Fresh HOME clone-free install smoke:
  `riela package install @tacogips/pdf-to-images-addon --refresh --scope project
  --no-dependencies --output json` installed from
  `https://github.com/tacogips/riela-packages/releases/download/registry-packages/pdf-to-images-addon.rielapkg`
  and wrote a lockfile with archive digest
  `sha256:6d0aedd8b512135f3cabe1a9f87d614dddd9ac165941f9162cde260beb0b63b6`.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'CommandParsingTests/testParsesNodeList|DoctorCommandTests|SetupContainerCommandTests|ContainerWorkflowAddonResolverTests|WorkflowPackageRegistryIndexTests|WorkflowCommandTests/testNodeSearchInstallAndRunProvideAddonLevelWorkflowlessEntryPoint|WorkflowCommandTests/testNodeInstallContainerAddonHintsSetupWhenRuntimeIsMissing|WorkflowCommandTests/testPackageInstallWritesProjectLockfileAndRemoveUpdatesIt|WorkflowCommandTests/testPackageInstallFromRielapkgPinsArchiveDigestInLockfile|WorkflowCommandTests/testPackageInstallFromIndexOnlyArchiveVerifiesDigestAndPinsReleaseURL|testPackageInstallWithoutTargetReplaysLockfileGraph|testPackageInstallLockedReplaysLockfileGraph|testPackageCIReplaysLockedSourceInstall|testPackageCIVerifiesLockedArchiveDigestBeforeInstall|testPackageInstallFromIndexOnlyArchiveDigestMismatchLeavesPriorLockfileIntact'`
  passed 37 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowCommandTests/testPackageInstallFromIndexOnlyArchiveVerifiesDigestAndPinsReleaseURL|WorkflowCommandTests/testPackageInstallWithoutTargetReplaysLockfileGraph|CommandParsingTests/testParsesNodeList|WorkflowCommandTests/testNodeSearchInstallAndRunProvideAddonLevelWorkflowlessEntryPoint'`
  passed after wiring default registry refresh to the release index.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SetupContainerCommandTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAddonsTests.WorkflowPackageManifestTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`
