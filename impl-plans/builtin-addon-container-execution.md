# Built-in add-on container execution

Request: every built-in add-on, including X gateway, should have a simple
container execution selection, supporting Apple Container and other runtimes.

## Findings

- Installed package add-ons already support container images and Containerfiles.
- Initially, the built-in resolver bypassed package container execution for
  every `riela/` and `kaiba/` name and `WorkflowNodeAddonRef` had no common
  execution selection. The production resolver now wraps this dispatch with
  the common `addon.container` selection and a versioned worker protocol.
- X/Gmail legacy container gateway entries previously returned success without
  calling a gateway. Their example bundles already specify images, query
  templates, environment bindings, and a runner kind.
- Apple Container runs Linux guests. Apple gateway framework/TCC operations
  require a macOS host service; moving an executable alone does not make them
  work in a guest.
- Live Apple Container 1.5.0 rejects file bind mounts; directory mounts work.
- A Linux build of local X gateway HEAD
  `0036445b73aa78d77d8467a1e2e9e7a15c406c66` fails because Foundation networking
  types are used without importing `FoundationNetworking`. Its portable image
  path requires upstream work or a maintained build integration.
- Git finalization acknowledgments and operation identities must remain owned
  by the runtime. A generic container protocol must retain these semantics;
  serializing `AdapterExecutionOutput` currently drops its internal finalization
  token.

## Work and acceptance gates

- [x] Replace the X/Gmail no-op dispatch with real pinned reader execution.
- [x] Reuse runtime drivers, explicit environment bindings, and declarative
  mounts. Reject invalid policies and failed/malformed gateway responses.
- [x] Verify gateway dispatch and installed-container regression tests.
- [x] Verify real Apple Container execution, including isolation and mounts.
- [ ] Provide an accessible, reproducible image build/install path. The X
  default GHCR image currently rejects anonymous pulls with HTTP 401.
- [ ] Add a common per-add-on execution selection, with a small default config
  and strict typed model validation, usable by all built-in names.
- [ ] Provide a first-party container worker and input/output protocol that
  retains variables, attachments, runtime identity, conditions, usage,
  finalization acknowledgments, and deterministic persistence semantics.
- [ ] Classify every catalog entry by portable execution or required macOS
  host integration; implement the required host integration for native actions.
- [ ] Integrate workflow/node CLI, registry, app editing/readiness, and preflight
  so container dependencies are checked at the actual execution boundary.
- [ ] Add full authoring examples and documentation for the common selection.
- [ ] Audit the complete built-in catalog and verify representative real
  container runs plus focused regression suites, arm64 build, and SwiftLint.

The gateway fix is a first step. Completion requires the remaining common
execution and host-integration work; gateway-only tests cannot prove the
request complete.

## Gateway-stage verification (2026-10-15)

The following commands ran from an arm64 shell with Xcode's Swift toolchain.
The focused test run passed 28 tests, including the real Apple Container
integration with a mounted deterministic reader fixture. This verifies the
container transport, argument binding, explicit environment, read-only root,
and network-denied configuration. It does not verify live X/Gmail accounts or
the unavailable default registry image.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product riela
RIELA_TEST_LIVE_CONTAINER=1 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'BuiltinContainerGatewayAddonTests|ContainerWorkflowAddonResolverTests|RielaBuiltinAddonCatalogTests|XDigestAddonTests|GmailDigestAddonTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/xcrun swiftlint lint --quiet --no-cache Sources/RielaCLI/ContainerGatewayAddonExecutor.swift Sources/RielaCLI/ProductionNodeAdapter.swift Sources/RielaAddons/RielaAddons.swift Tests/RielaCLITests/BuiltinContainerGatewayAddonTests.swift
git diff --check
```

Build, focused SwiftLint, and diff checks passed. The Linux X gateway source
build and anonymous GHCR image pull failed for the reasons listed above.

## Common worker stage (2026-10-15)

Implemented the typed `addon.container` object, a production resolver wrapper,
`riela-addon-worker`, and JSONL execute/acknowledge/terminal messages. Requests
keep runtime identities, inputs, variables, and attachments; replies retain
conditions, usage, completion status, and an internal finalization token.
Acceptance returns to the original container transport. Host environment
bindings are resolved once and rewritten to guest target names. Workspace and
worker state are mounted without implicitly mounting the host home directory.

The node CLI accepts `--container`, `--container-image`,
`--container-options`, `--config`, and `--env`. An empty common selection on
legacy X/Gmail readers retains their configured mounts and network denial.

Verification passed:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --jobs 4 --filter 'BuiltinAddonContainerProtocolTests|BuiltinAddonContainerResolverTests|WorkflowAddonExecutionIdentityTests|BuiltinContainerGatewayAddonTests|ContainerWorkflowAddonResolverTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --jobs 4 --filter 'BuiltinAddonContainerResolverTests|BuiltinAddonContainerProtocolTests'
```

The broader run passed 41 tests with one opt-in live-container test skipped.
After adding the legacy compatibility regression, the focused run passed all
11 tests. The standalone worker process executed a real time-signal operation
through JSONL, and the native node CLI applied config correctly. Focused
SwiftLint and `git diff --check` passed. An earlier test build was invalidated
by edits during compilation; the successful runs used stable sources.

The image source is `containers/builtin-addons/Containerfile`, built with
`scripts/build-builtin-addon-container.sh`. The script stages a small context
under repository `tmp/`, excludes generated artifacts, and discovers the
container runtime. The first staged image build reached SwiftPM but failed
because root test targets were missing from the context. The context now
includes `Tests/`; the updated Linux image build completed successfully.

The built image `riela-builtin-addons:local` has manifest-list digest
`sha256:d8f83d7aecbec54b33097595a7662c1b2e3a19eb3eba64e231d56db25ecdbd84`.
Apple Container CLI runs verified real `riela/time-signal`, `riela/kv-set`, and
`riela/kv-get` operations with `--container`, runtime `apple-container`, and
network policy `denied`. The KV value written by one container was read back
from another container's workspace database. The base image has the required
SQLite runtime library, and live mount ownership matches the guest process.

Terminal control is now routed only for add-ons that return an internal
finalization token or are Git add-ons. Non-finalizing workers do not receive
Git cleanup requests. After this change, all 12 focused protocol/resolver tests
and focused SwiftLint passed:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --jobs 4 --product riela-addon-worker
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --jobs 4 --filter 'BuiltinAddonContainerResolverTests|BuiltinAddonContainerProtocolTests'
scripts/build-builtin-addon-container.sh container riela-builtin-addons:local --progress plain --cpus 4 --memory 8G
```

The image includes the common worker and CLI; it does not yet provide portable
X/Gmail reader images or the macOS-only dependency bridge. The latest terminal
transport filter is on the host; rebuild the image after subsequent worker
changes before the final completion audit.

Remaining completion work includes the full Linux image and catalog, native
macOS integration, app/preflight integration, and end-to-end persistent
finalization/resume verification. Current in-memory transport routing alone
does not prove terminal callbacks are routed correctly after a fresh resolver
is created for a resumed execution.


## Storage reduction and clarified isolation objective (2026-10-15)

The user clarified that the purpose is isolation of AI-executed work, with
minimal disk use, rather than containers as the only implementation strategy.
The previous full Swift runtime image carried the compiler and was roughly
3.6 GB when unpacked. All three Containerfiles now separate compiler builds
from Ubuntu runtime images. Apple Container inspection reports compressed
variant layer totals of 107,932,591 bytes (X), 113,167,541 bytes (Gmail), and
196,197,738 bytes (common worker). These are not unpacked disk measurements
and exclude build caches, compiler base images, and VM resources.
The reduced X image starts successfully and its offline health command passes.

The isolation scope must include AI command execution, file operations, and
spawned child processes. Add-on-only execution does not achieve that objective.
A native macOS process sandbox using Seatbelt/sandbox-exec and a Linux backend
using bubblewrap are candidates for avoiding OS image duplication. Neither is
implemented in Riela yet. The native backend must fail closed, avoid silently
falling back to unrestricted execution, explicitly bind workspace and secrets,
and verify forbidden file access, writes, IPC, network and subprocess behavior.
Host Apple API access needs a narrowly scoped broker instead of broadly opening
host access. Keep container execution available when a guest kernel boundary
is required. This extends the remaining completion work; the goal is unfinished.

References checked: https://github.com/anthropics/sandbox-runtime,
https://hermes-agent.nousresearch.com/docs/user-guide/features/tools,
https://docs.openclaw.ai/sandboxing. Hermes supports persistent Docker terminal
execution and SSH/cloud alternatives; OpenClaw isolates tool execution through
sandbox backends. These patterns motivate separating the runtime control plane
from the execution boundary.


## Durable callback transport and runtime dependency selection

Container callback routing now persists settings and explicit environment
binding names under workspace `.riela/addon-container-state/transports`.
Tokens and workflow execution ids remain those issued by the runtime/worker;
transport metadata does not create runtime identities. Git workflow routing is
persisted before the side-effect process starts. A fresh resolver can locate
acceptance and terminal transports. Callback credentials are resolved anew,
allowing rotation, and unavailable required credentials fail without native
fallback. The selected runtime command is retained for callbacks. Acceptance
records are removed only after successful acknowledgement and workflow records
only after successful terminal dispatch. SwiftLint is being checked together
with restart and missing-credential regressions.

The first live Gmail test failed because its assertion required an exact object
containing only id, whereas the gateway returns additional account metadata.
The fixture did load and return the expected configured account. The assertion
now checks its id, address, count, and non-fallback status instead.

`collect-swift-runtime.sh` selects the transitive shared Swift libraries reported
by ldd for the built binaries. Final images exclude compiler tools and unused
Swift libraries. Unneeded system ICU packages are removed, since the selected
Swift Foundation libraries use their own ICU library. Standalone gateway images
also omit SQLite. Rebuilt compressed layer totals are 87,953,716 bytes (X) and
93,188,681 bytes (Gmail); live verification of these exact images and the new
common image remains a required gate. Build caches are separate storage.


The focused protocol/resolver and opt-in real image run passed all 16 tests,
including both X/Gmail mutation rejection and mounted Gmail account metadata.
The exact reduced images also pass standalone offline probes. Their unpacked
root file totals are 268,849,152 bytes (X) and 283,713,536 bytes (Gmail), with
selected Swift shared libraries accounting for approximately 76 MiB. These
measurements exclude VM disks and build caches. Focused SwiftLint and
`git diff --check` pass. The common image dependency rebuild is still running;
it must be checked before claiming the common image matches current sources.
The complete built-in catalog, macOS bridge, and native AI sandbox remain
unfinished, so the original goal is not achieved.


## Wrike SDK Linux integration (2026-10-15)

The fixed Wrike revision already supplies Linux URLSession and loopback OAuth
implementations. Removed Riela's macOS-only link condition for WrikeGatewayAdmin,
so its cumulative SDK tiers are available to the Linux worker. The pinned source
was fetched into task scratch and all reader/writer/admin products were compiled
in a Swift Linux container with network denied. Real reader and writer probes
returned CAPABILITY_DENIED for createTask and deleteTask respectively. The admin
account query returned AUTHENTICATION_FAILED without a credential. This validates
linking and tier enforcement, not successful authenticated API requests.
The scratch checkout and compiler outputs were removed after saving the results.

The focused worker/resolver plus Wrike suites passed 22 tests. The image gate
compile run passed 24 tests with two opt-in tests skipped. The opt-in tests cover
all three Gmail SDK modes and Wrike read/write tier rejection plus admin missing
credentials in the actual common worker image. They must run with
RIELA_TEST_LIVE_BUILTIN_IMAGE=1 against an image rebuilt after the manifest change.
SwiftLint and git diff --check passed. The running common-image build uses an
older staged manifest without the new Wrike condition; it remains useful for
verifying the minimal runtime, but cannot establish Wrike completion.

A locked SwiftPM builder cache has been added to the common Containerfile.
Compilation and copying binaries/resources happen in one RUN while the cache
is mounted, so cached build outputs never enter the final runtime image. This
new build definition still needs real build verification. Do not claim its
cache behavior is verified by the older staged build.

For macOS-only catalog entries, the existing AppleGatewayInvoker seam is the
appropriate dependency boundary to investigate next. Keep add-on rendering,
validation, selection and runtime output processing in the guest. A host broker
would execute only native Apple gateway operations granted for the selected
add-on, with bounded requests and no generic host shell escape. The broker is
not implemented; Apple and remaining platform-specific catalog coverage is
still incomplete.


## Native Apple bridge implementation and minimal common image

Implemented an operation/field grant for all 32 fixed Apple catalog entries,
using the pinned Wrike parser to validate the constrained generated GraphQL
syntax rather than matching untrusted text. Query and mutation grants are
separate; unrelated root fields, aliases, fragments, extra CLI flags and malformed
variables fail closed. Mutations have a one-operation budget to prevent repeated
side effects under new guest-generated RPC correlation ids.

Added bounded file RPC over pinned POSIX directory descriptors. Existing secure
filesystem primitives reject symlinks, foreign hardlinks, nonregular records and
oversized messages. Host channel creation and cleanup use directory descriptors,
so guest path replacement cannot redirect cleanup outside the owned directory.
The worker protocol carries an optional native Apple bridge directory, valid only
for execute requests. The guest injects this dependency into the existing
AppleGatewayRunner seam. The container resolver supplies the scoped host broker
on Darwin; this keeps add-on logic in the guest and only native API execution on
the host. Non-Darwin hosts reject this bridge. Guest requests contain no host
environment bindings or arbitrary executable selection.

Focused bridge, capability, protocol and resolver suites passed all 23 tests.
They include worker output processing through a substituted native dependency,
automatic container selection wiring, cleanup, scope escalation, repeated
mutation refusal and a request symlink. SwiftLint and git diff --check pass.
An opt-in real guest/native-dependency integration test compiles but was skipped
until the rebuilt image is ready. These results do not prove live TCC behavior,
materialized attachment transfer or general Apple gateway admin operations.

The previous minimal common image finished with digest
sha256:b81d166058a68891ce9546e2d576be3539bce255f5f526bed6b3ebd0cfd81dd3
and compressed layer total 177,080,670 bytes. Its three real Gmail SDK modes
passed offline account metadata execution in the actual worker image. That
check used the already compiled integration test binary; it is compatible with
the old protocol for Gmail but does not validate new native-bridge functionality.
A new source-matching image build with Wrike and the native bridge plus the locked
SwiftPM builder cache is running. Its handle and logs belong only in task scratch.


## Real guest bridge verification and administrative command grants

The source-matching Wrike/native-bridge image completed with digest
sha256:3a8b21e12610a16a25be63a8a6000524c0cc0edb956d2900c1ecd1f1cdd02ede
and compressed layer total 179,535,707 bytes. All three opt-in real guest tests
passed: Gmail SDK modes, Wrike capability tiers/admin missing credentials, and
Apple add-on processing over the actual Linux guest/native-dependency transport.
The Apple dependency was substituted, so that test did not delete real Notes.

Extended the native grant to the seven general Apple gateway administrative
add-ons. The host reconstructs their command from the original inputs and accepts
only that exact argv, preventing guest changes to permission domains, query text,
keys or cache operations. Native file paths map through workspace and explicit
mounts with the most specific target taking precedence. Writes to read-only
mounts and traversal outside an exposed root fail. A regression found Foundation
symlink resolution did not resolve an intermediate symlink when the final file
was missing; resolving the existing ancestor first fixes that case.

The focused administrative/bridge/path run passed 16 tests, with four opt-in
image tests skipped. It executes all seven administrative wrappers in a guest
process stand-in using the real worker, but substitutes only the native command
runner. SwiftLint and diff check pass. A new opt-in real native SDK schema test
is compiled and awaits an image containing the administrative extension.
The rebuild is running with the locked builder cache from the prior image.

Remaining native work includes attachment/body file dependencies, strong pinned
reads for administrative query/variable/config files (path mapping alone is not
a proof against later filesystem replacement), guest/host output-path translation,
and live TCC behavior. Neither these focused tests nor command grants establish
completion of every optional Apple behavior. The full goal stays unfinished.


## Pinned native input and dependent file materialization

The administrative image finished with digest
sha256:75528aa9f1d04afeba0f681123b10df815b493d6297a3c6657529a4fc99f5763
and compressed total 179,587,975 bytes. Four real guest tests passed, including
schema retrieval through the actual linked native Apple SDK on the host.

Administrative file reads now use no-follow directory walks. Query and variable
files become inline strings; config files are copied into bounded anonymous
snapshots whose descriptors remain live through the SDK call. Tests prove path
replacement cannot redirect a pinned read and in-place changes do not affect the
config snapshot. Native request and variable bounds now match the main 64 MiB
protocol limit instead of a lower incidental limit.

Implemented dependent downloads for note-get and mail-message. Keys must come
from successful native response data in the same invocation. Unapproved keys,
extra flags and non-writable output mounts fail closed. Output publication retains
the destination directory descriptor and translates paths back to the guest.
A first implementation tried `/dev/fd/<directory>/child`; macOS rejects that path.
The corrected implementation stages outside exposed roots and exclusively streams
regular output files into the pinned directory. This also supports renamed output
directories without writing through a replacement symlink. Transfer loops check
the execution deadline and keep memory bounded to a 64 KiB copy buffer.

The combined run passed all 22 tests with opt-in guest tests enabled. It includes
five real guest cases: Gmail modes, Wrike tiers, native Apple schema, substituted
Apple operation, and Note body materialization through a mount with a different
guest target. Native API dependencies for data mutation/materialization remain
substituted, so no real Notes were deleted or downloaded. Source-staging tests use
a task-local staging-root override under repository tmp. SwiftLint and diff checks
passed. The current image predates the new host-only pinning/materialization
helpers; it implements the compatible guest protocol used by these tests. Final
source-matching image rebuild remains required after subsequent catalog changes.

Further work: Mail body/attachment variants, real native file-store error cases,
remaining cloud SDKs, Kaiba and AI worker profiles/tools, native process sandbox,
app readiness, and full catalog/finalization completion audit. The goal remains
active and incomplete.


## Google Analytics SDK Linux build

Added a pinned analytics source stage at revision
c46443a5e8f744244cb9825d3238958a797c4f2b to the common worker image. Adaptations
are confined to build copies: Darwin/Glibc imports, Linux SOCK_STREAM raw value,
Darwin-only sockaddr length, nanosecond stat fields, portable Swift Crypto, and
SIGPIPE-safe send on Linux in place of Darwin SO_NOSIGPIPE. Original socket
loopback constraints and stable-file metadata comparisons are retained.
Exact replacement anchors failed first on a repeated manifest substring and then
on a previously unguarded SO_NOSIGPIPE symbol; both were fixed using the actual
pinned source. The image then built with all three SDK modules, digest
sha256:2d9d32622fa646ac0acc7119da8a366f877f8ea2ceebe5096081902d3630e44b,
compressed layer total 182,631,651 bytes.

The six-case real image run passed the previous five cases and the Analytics
reader/write escalation checks, but its admin read check failed with unknown
query field gtmAccount. Inspection found Riela registered only AdminCapabilities,
whereas the dependency CLI registers Read + Write + Admin fragments. Fixed the
Riela writer/admin composition to match those primary entrypoints. Added a
lower-tier inclusion regression and rebuilt the source-matching image; host tests
and rebuild are still running. Do not treat the first image or partially passing
live run as proof of Analytics completion. Fresh live gates remain required.

The Python adaptation script parses and the focused SwiftLint/diff checks pass.
The opt-in Analytics test compiles; its administrative credential assertion is
not yet verified against the cumulative-registry image. Separate native OS sandbox
support remains an optional alternative researched earlier, not a requirement for
proving the original container goal. AI SDKs and their child tools still must be
verified within the container boundary to satisfy that goal.


The cumulative capability regression and existing Analytics host suite passed:
15 tests total, with all nine executed tests passing and six opt-in image tests
skipped. SwiftLint passed. The corrected image build remains live; repeat the
six real guest gates after import before claiming Analytics runtime coverage.


## Documents SDK build-copy portability

Prepared revision cda93cdd770a51f6f9d1bc63b1db555884824606 for Linux in the
common image. Added portable Crypto and FoundationNetworking/CoreFoundation
imports. Preserved the original macOS Network callback implementation and added
a Linux POSIX callback listener bound only to 127.0.0.1, with bounded request size,
connection budget, polling deadlines, and MSG_NOSIGNAL sends. The shared existing
request parser and login state/PKCE validation remain in use. Linux browser
opening uses xdg-open when requested; workflow add-ons still disallow interactive
auth commands. This source path needs actual Linux compilation and runtime gates.

Added the committed support fragment under scripts/container-gateway-support and
included it in staged build contexts and .dockerignore. The initial root-manifest
adaptation failed because the final package dependency has no trailing comma;
the exact anchor was corrected and all three local gateway dependency rewrites
were verified in a scratch manifest before retrying the preview build.

The existing Analytics cumulative-registry build remains active and CPU-busy.
The separate documents-preview build has reached its SwiftPM RUN and waits for
the same locked cache. Do not restart either solely because log output pauses.
Added a seven-case image suite with a six-role Documents dry-run case; it can
select a preview via RIELA_TEST_BUILTIN_IMAGE. The test flag contract uses
argsTemplate, as required by the real adapter. Lint and diff checks pass; fresh
compile and all live gates remain to be collected. No Documents completion claim
is supported yet. The original all-built-in goal remains incomplete.

### Lightweight image and Documents cumulative verification (2026-10-15)

The Documents preview image completed its Linux release build. Its compressed
OCI manifest reports 183,324,228 bytes. This excludes the compiler image,
builder cache, unpacked guest layers, VM disks, and host SwiftPM outputs.
The seven opt-in BuiltinAddonImageIntegrationTests passed against that preview:
Apple host dependency/schema/body transport, Gmail modes, Analytics capability
tiers, six Documents/Sheets/Drive dry-run roles, and Wrike capability tiers.
These offline gates do not claim authenticated production API coverage.

Claude and Cursor SDK worker catalog entries now match existing executable
resolution, with focused catalog tests passing. The SDK HTTP fixture gate is
being checked separately. Native OS sandboxing remains a design option rather
than an implemented Riela backend; other project comparisons and minimal
runtime dependency guidance are recorded in docs/container-addons.md.

The attempted host-HTTP SDK fixture is not a valid integration gate:
AgentProviderConfiguration deliberately accepts plaintext HTTP only for loopback,
and the container gateway IP is not loopback. No provider request was emitted.
The exploratory fixture was moved to scratch rather than weakening URL policy or
leaving a known-failing test. A guest-local fixture or trusted TLS fixture remains
necessary for SDK network proof. This is not evidence of working AI execution.

### Guest-local SDK provider gate (2026-10-15)

Replaced the invalid host-IP plaintext fixture with a test-only guest-loopback
Swift HTTP provider. The test derivative image adds no dependency to the product
image and runs with networkPolicy denied. All four SDK workers returned the
expected text, and receipts showed the OpenAI Responses, Anthropic Messages,
Gemini streamGenerateContent, and Cursor Agents routes. The opt-in integration
test passed. This proves guest HTTP SDK execution; it does not claim real vendor
credentials, remote agents' execution environments, or arbitrary tool isolation.

### Document converter Linux provisioning (2026-10-15)

Removed the macOS-only AnydocKit link condition and provisioned the exact pinned
Rust static library through a separate build stage with Cargo --locked. The
runtime image receives only the linked Swift executable and its shared-library
dependencies. Added a real guest CSV conversion test. Host converter tests passed
15 cases; eight opt-in guest gates compiled and skipped in that run. Linux image
build and real conversion proof remain pending until the running build completes.

The Google Service read/write SDK now also has a passing real-guest gate with
network denied: cross-tier operations are refused and each allowed tier requires
its explicit token binding. These are capability/credential checks, not live
Google Service API calls. The Rust static library build has completed and
AnydocKit has compiled on Linux; the worker image release build is still running.

### Kaiba captured instance transport and converter linker (2026-10-15)

Added a credential-free typed Core DTO for only the preflight-selected Kaiba
instance. The resolver retains the stable binding ID and connection flags, binds
only that instance's credential, and rejects conflicting credentials or a missing
snapshot before launch. Worker preflight consumes this captured instance rather
than loading its isolated HOME catalog. Protocol scope tests prevent attaching the
instance to another binding, another add-on family, or finalization control.
Focused resolver/protocol/session-preflight tests passed 21 cases; SwiftLint passed.
The two opt-in SDK/Kaiba guest gates compile but need the updated fixture image.
Host-loopback Kaiba endpoints still need a dedicated reachable transport; they are
not claimed as supported by the current projection alone.

The first Linux converter image reached final linking, where GNU gold rejected
Rust ARM64 relocation 315. Switched the builder to LLD (provisioned only if missing)
without adding a runtime dependency. A replacement source image includes these
Kaiba changes and is building; the original failed image was not promoted.

### Kaiba host-loopback transport (2026-10-15)

Implemented a separate pinned-directory RPC service for captured loopback Kaiba
instances. The guest sends only the GraphQL body and a bounded response limit.
The host selects the captured endpoint and headers, retains the credential, uses
the existing bounded/nonredirecting SDK transport, and enforces request/execution
deadlines. Remote instances still use ordinary guest networking. The worker builds
its captured client with a nonsecret placeholder when using the host bridge; it
never reloads the catalog. HTTP auth status survives the transport, and host SDK
redaction is applied to GraphQL error diagnostics.

Focused transport/resolver/protocol tests passed 22 executed cases; two opt-in
image tests compiled and skipped. Tests cover destination/header override attempts,
remote host-bridge rejection, deadline and response-limit rejection, auth/error
propagation, and keeping the loopback credential out of guest arguments and wire
records. SwiftLint passed. A real host-loopback fixture test is ready for the
updated worker image; its result remains pending.

### Native converter build smoke (2026-10-15)

LLD removed the relocation failure but the LTO archive still had unresolved
encoding_rs constants. The replacement archive disables Rust LTO while retaining
release optimization. It compiled and passed a real C ABI CSV conversion smoke
inside the Linux build stage before Swift compilation. The complete worker image
build is running; no failed/partial image has replaced the default local tag.

### Real image and durable Git resume gates (2026-10-15)

The non-LTO/LLD worker image built successfully (compressed OCI manifest
197,279,271 bytes). Nine real image gates passed, including CSV conversion,
Documents roles, gateway tiers, and native Apple transport. A real host-loopback
Kaiba fixture also passed with guest networking denied and the selected credential
applied only by the host. All four SDK provider routes passed again against a
derivative fixture image based on this worker.

Review exposed that guest-writable transport metadata could alter the host's
future image/runtime/credential selection. Moved that authority to host-only
~/.riela/addon-container-transports/<workspace-hash>. Explicit mounts/workspaces
that expose the control or whole worker-state namespaces are rejected, including
legacy X/Gmail mounts. Durable acknowledged markers handle repeated acceptance
without another guest process or native-resolver fallback.

The first real Git run correctly refused finalization state inside the repository.
Worker state now has a separate persistent host directory, mounted at
/var/lib/riela/state, with HOME beneath it. Host preparation walks components
without following symlinks; it does not chmod shared ancestors. A real guest Git
commit now survives a controlled runtime budget stop, SQLite reopen, fresh
resolver reconstruction, acceptance reconciliation, and execution of the next
step. Session/execution IDs are retained and no second commit is created. The
standalone Git/resolver gate passed 15 cases. A combined image/state gate is being
collected, and an image rebuilt from the updated state/control sources is running.

The combined gate completed: 28 tests passed, none skipped. It includes all nine
real image gates, four SDK provider routes, host-loopback Kaiba, SQLite Git reopen
and resume, resolver authority isolation, and symlink-safe state preparation.
SwiftLint and git diff --check passed for this change set. Remaining completion
work includes catalog-family coverage, Mail file variants, App/workflow entry
points, and a final source-matching image/default-tag audit.

### Catalog, stateful execution, Mail, and entry points (2026-10-15)

Source-to-catalog comparison found two implemented but unregistered memory
operations. Registered memory-update and memory-search; the catalog now has 108
unique entries. Five real guest tests passed memory/KV CRUD, all six routine
operations, persona memory/router/reply/handover, and both digest state readers.
The four catalog/host validation gates passed as well. All 29 Kaiba add-on family
tests passed, including the long-term memory contracts.

The generated-workflow add-on now has a real guest integration gate: generation,
registration in guest state, child runtime execution, and runtime-owned session
identity passed using a test-only vendor CLI stand-in. This fixture is not shipped
in the product image; CLI-based child workflows still require their declared CLI
in a custom image, while HTTP SDK workers require no Node/vendor CLI.

Mail's host grant omitted permissions/mailAccounts/mailboxes even though its real
query requests them. Corrected the read grants. Real guest Mail list/FDA refusal,
text/HTML/raw/attachment materialization with filename containment, and a real
native FileStore invalid-key error all passed. The latter uses a scratch config
and never reads real Mail data.

CLI node run previously skipped Kaiba preflight when container selection was set,
which lost the captured instance. Fixed that condition. An actual RielaCLIApplication
node run --container invocation passed for time-signal and a named loopback Kaiba
instance, including creation of separate guest state; two App Kaiba readiness
regressions also passed. Production resolver call-site inspection shows workflow
run, node run, resume/rerun, direct step execution, and distributed execution use
the common wrapper. The only direct native fallback is strict mock verification.

Completion audit still needs native configuration authority: explicit guest config
files are snapshotted, but embedded storage.cache_dir is consumed by the host SDK.
FileStore creates that directory, and cache prune removes managed children there.
Constrain it to host-managed service storage outside guest shares before release;
add a harmless outside-workspace sentinel test to prove refusal. File-download's
omitted outputDir also needs a guest-workspace default, so native SDK defaults do
not materialize final outputs into the host cache. These are active implementation
items, not completed security claims. Final source image must include the catalog,
Mail grant, and CLI preflight changes (state-preview predates them).

### Native configuration authority gate (2026-10-15)

Closed the configuration-content authority gap: host-linked Apple calls reject
configurations that replace the host cache, Mail root, helper executable, domain
policy, or audio device selection. Host config/cache/helper paths must be outside
all guest shares in both overlap directions. Guest config snapshots can still
tune request limits. Regression fixtures preserve an outside-workspace sentinel
and reject cache/share overlap. The default file-download destination is now
workspace/tmp/apple-gateway/downloads, with staged publication to guest output.
All 20 focused Apple bridge/config/path tests passed, including four live guest
Mail/download gates. All 56 changed Swift files passed SwiftLint with no warnings;
no changed Swift file exceeds 1000 lines. The common protocol/resolver/state and
capability gate passed 45 tests with the optional legacy live test skipped.
Final source-matching image build is in progress; earlier state-preview remains
only a compatibility fixture until that build and its live gates finish.

### Completion verification (2026-10-15)

The source-matching arm64 worker image passed 21 real guest gates with no skips
or failures. A test-only derivative from that exact image passed the four-provider
SDK and generated child workflow gates (2 tests). The dedicated X/Gmail reader
images passed 2 offline integration gates. An additional production CLI invocation
passed after promoting the default tag and removing the old short-name image;
Apple Container can retain distinct short and canonical references, so both
lookup and execution of the default name were checked.

Default image: riela-builtin-addons:local
Index: sha256:0116c62885076a5f971f02628edf23d0793c09fa355dc01be36b1e2762c55228
Compressed variant bytes: 138915421
Runtime filesystem files: 396232 KiB (approximately 387 MiB)
Executables/resources: approximately 80 MiB after stripping DWARF
Selected Swift libraries: approximately 76 MiB
Host common-image snapshot allocation: approximately 1.5 GiB

The runtime has no Swift compiler, Node.js, Python, or Cargo. The build-only
compiler images, builder VM/cache, and old preview/provider fixture images were
removed after testing. Measured Apple Container directory usage fell from about
75 GiB immediately before cleanup to 6.3 GiB; this retains the common, X, Gmail,
and required base/system images and their snapshot overhead. The repository's
existing SwiftPM .build remains available (approximately 3.7 GiB); it is separate
from container runtime dependencies and was not deleted.

All 56 changed Swift files passed Xcode SwiftLint; focused protocol/resolver/state
and capability tests passed 45 cases, with one optional legacy live fixture
skipped. Twenty Apple bridge/config/path cases passed, including four guest Mail
and download tests. Shell syntax and Python compilation checks passed, and git
diff --check is clean. Commands and opt-in flags are documented in
`docs/container-addons.md`. No external provider writes or real Notes/Mail changes
were used for verification. User-specific TCC grants and authenticated vendor
services remain environmental requirements, rather than unsupported dispatch
paths. A native OS process sandbox is a documented alternative, not an implemented
Riela backend; this completion covers built-in container selection and runtime
image dependency reduction.
