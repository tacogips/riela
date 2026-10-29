# Container add-ons

## Common built-in execution selection

Add `container: {}` to an add-on reference to select the first-party worker:

```json
{
  "id": "clock",
  "addon": {
    "name": "riela/time-signal",
    "version": "1",
    "container": {},
    "inputs": {
      "scheduledAt": "2026-10-15T00:00:00Z",
      "timezone": "UTC"
    }
  }
}
```

The same selection is available from the node CLI:

```bash
riela node run riela/time-signal --container \
  --variables '{"scheduledAt":"2026-10-15T00:00:00Z","timezone":"UTC"}'
```

`--container-image <image>` overrides the worker image. `--container-options`
accepts a JSON object or JSON file reference with `image`, `runtime`,
`networkPolicy`, and `mounts`. The workflow field uses the same object:

```json
{
  "image": "riela-builtin-addons:local",
  "runtime": "apple-container",
  "networkPolicy": "denied",
  "mounts": []
}
```

The default worker image is `riela-builtin-addons:local`. The source build is:

```bash
scripts/build-builtin-addon-container.sh
```

The script discovers Apple Container, Docker, or Podman and stages only the
required source under repository `tmp/`. Pass `docker` or `podman` as the first
argument to select those runtimes. The image build and time-signal/KV execution
have been verified with Apple Container. The common selection does not make
macOS-only gateway dependencies portable. See the current scope below.

The image uses separate build and runtime stages. The Swift compiler, package
sources, and build tools remain in the build stage. The runtime stage contains
Ubuntu, the transitive Swift shared libraries used by the compiled executables,
and system dependencies;
the common worker also includes Git and OpenSSH for Git add-ons. These are
execution images, not environments for compiling arbitrary AI-generated Swift.
Build caches and the compiler image still consume local storage independently
of the runtime images.

The verified arm64 common image measures 138,915,421 bytes (about 139 MB)
compressed, with 396,232 KiB (about 387 MiB) of files inside its root filesystem.
Compiled executables/resources occupy about 80 MiB and selected Swift libraries
76 MiB. Build-only DWARF sections are stripped from the executables. These figures
exclude VM disk overhead, compiler base images, builder caches, and the host
SwiftPM `.build` directory; they are not total host storage usage. The materialized
Apple Container snapshot for this common image occupies about 1.5 GiB on the
host, so 387 MiB must not be interpreted as its complete host disk allocation.
Do not install Node.js, vendor agent CLIs, or a Swift compiler merely to run
the built-in HTTP SDK workers: those workers use the linked Swift SDKs.

## Video media add-ons

The `riela/media-download`, `riela/audio-segments`, `riela/video-frames`, and
`riela/speech-to-text` add-ons select `riela-video-addons:local` when their
container options omit `image`. The compatibility name
`riela/video-transcribe` selects it too. An explicit `image` always takes
precedence. The video image extends the common worker with ffmpeg/ffprobe,
yt-dlp, and Deno.

Build the common worker first, then build the video image:

```bash
scripts/build-builtin-addon-container.sh
scripts/build-video-addon-container.sh
```

On macOS, start Apple Container before the builds with `container system start`
if its service is not running. The video build script discovers Apple Container,
then Docker, then Podman, and accepts a runtime name and base image as its first
two arguments.

Downloading media and speech-to-text require network egress. Set
`networkPolicy` to `egress-allowed` for those stages. Audio segmentation and
video frame extraction can use `networkPolicy: "denied"` when their input files
are already present. The workflow working directory is the only directory
shared at the same path, so keep each stage's `outputDir` beneath that directory
and pass generated files between stages there.

Container execution of an add-on does not by itself isolate an AI agent's shell,
file tools, or other child processes. Agent execution needs its own enforced
filesystem, environment, IPC, and network boundary, applied to the whole process
tree. A native OS sandbox is an alternative to Linux container images for
compiled Swift processes. Native sandbox selection is being implemented; see
[execution sandbox backends](execution-sandbox.md) for the current verified scope
and outstanding integration gates.

For a future native backend, the isolation boundary must cover the worker and
its entire child-process tree, with explicit workspace, credential, IPC, and
network permissions. On macOS, a signed App Sandbox helper or a Seatbelt
process wrapper can reuse the installed system rather than shipping a Linux
image. Linux can use bubblewrap with syscall and network restrictions. The implementation and verification status of these native execution settings
is tracked in [execution sandbox backends](execution-sandbox.md).

Other agent projects make the execution boundary explicit:
[Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools#terminal-backends)
offers local, Docker, SSH, and remote sandbox backends; its Docker backend
shares one persistent container across terminal, file, and code-execution calls.
[OpenClaw](https://docs.openclaw.ai/install/docker/sandbox-and-troubleshooting)
can leave the gateway on the host while executing tools inside a sandbox.
[Anthropic sandbox-runtime](https://github.com/anthropics/sandbox-runtime)
uses macOS sandbox-exec or Linux bubblewrap with network filtering without
requiring a container; adopting that Node.js package is not required to use
the underlying OS facilities from Swift.

The worker receives one versioned JSONL request containing the original
variables, inputs, attachments, and runtime execution identity. Its reply
preserves output conditions and usage. Finalization tokens stay internal to
the runtime. Host-only transport metadata under
`~/.riela/addon-container-transports/<workspace-hash>`
lets a fresh resolver route acceptance and terminal callbacks back to the worker
image and mounts. Only environment binding names are persisted; credentials are
resolved again when callbacks run, allowing credential rotation. Missing required
credentials fail an outstanding callback without falling back to native execution.
A durable acknowledgment marker prevents repeated callbacks from launching a guest
or falling through to the native resolver. Workspaces and user mounts must not
expose the reserved control or worker-state namespaces.

The workflow working directory is shared read-write at its original absolute
path. Worker home and Git finalization state persist on the host in
`~/.riela/addon-container-state/<workspace-hash>`, mounted read-write at
`/var/lib/riela/state` in the guest. `HOME` is `/var/lib/riela/state/home`.
Keeping Git finalization storage outside the repository preserves its existing
security contract. State directory preparation refuses symlinks rather than
following guest-controlled paths on the host. Add-ons retain their
existing workspace-relative state paths, such as `.riela/kv` for KV storage.
The container root is read-only with writable `/tmp`, and its `HOME` belongs to
the worker state directory. Host home directories and credentials
are shared only when explicitly mounted or bound. Only `addon.env` bindings
and the credential environment binding of a remote captured Kaiba instance are
forwarded; `HOME` and `RIELA_ADDON_STATE_DIR` are reserved for the runtime.

For direct node runs, `--config` provides add-on config and `--env` provides
the `addon.env` binding object, using JSON objects or file references.
Run mutating Git add-ons through a workflow, which provides their required
execution identity.

## X and Gmail container readers

For host-side credential setup and native gateway authentication, see
[`riela gateway`](gateway-cli.md).

For existing X/Gmail references, adding `container: {}` retains legacy image,
mounts, and network denial from `config`. Non-default common options override
the corresponding legacy choices. `networkPolicy: "denied"` takes precedence
over an existing egress allowance.

`riela/x-gateway-read` and `riela/gmail-gateway-read` execute the gateway's
reader executable inside a Linux container. They no longer return a placeholder
success without executing the query. A missing runtime, failed process,
malformed response, or gateway error fails the step.

```json
{
  "id": "fetch",
  "addon": {
    "name": "riela/x-gateway-read",
    "version": "1",
    "config": {
      "queryTemplate": "query { accountMe { id username } }"
    },
    "env": {
      "X_GW_ACCESS_TOKEN": { "fromEnv": "X_GW_ACCESS_TOKEN" }
    }
  }
}
```

Runtime discovery prefers Apple Container on macOS, then Docker and Podman.
Start Apple Container with `riela setup container --yes`.
`RIELA_CONTAINER_RUNTIME=container`, `docker`, `podman`, or an executable path
overrides discovery and `config.runnerKind`. Optional `runnerKind` values are
`auto`, `apple-container` (or `container`), `docker`, and `podman`.

The default images are `riela-x-gateway:local` and
`riela-gmail-gateway:local`. Build the pinned source images with
`scripts/build-gateway-container.sh x` and
`scripts/build-gateway-container.sh gmail`. `config.image` overrides the image;
use a digest reference for reproducible execution. The image must contain
`x-gateway-reader` or `gmail-gateway-reader` on its PATH. The entrypoint is pinned
to that reader. X receives `graphql query <rendered-query> --json`; Gmail
receives `graphql --query <rendered-query>`. No shell evaluates the query.

Gateway failures retain only finite machine diagnostics: SDK code/classification,
HTTP status, allowlisted provider problem/reason, and a bounded integer provider
error code. Provider messages, details, resource IDs and arbitrary URLs are
excluded; unknown diagnostic strings are discarded.

Only `addon.env` bindings are forwarded into the container. Gateway target names
must be uppercase `X_GW_*` or `GMAIL_GATEWAY_*` names (letters, digits, underscore);
source names in `fromEnv` are unrestricted. Host runtime controls such as `PATH`,
`HOME`, `DOCKER_HOST`, and loader/interpreter variables cannot be addon targets.
Docker and Podman receive values through the runtime process environment using
name-only `-e NAME` arguments and disable output persistence with `--log-driver
none`. Custom runtime wrappers must enforce their own logging policy.

Apple Container uses a secret-free, bounded idle init and attached `exec` because
its init stdout/stderr are persisted in `stdio.log`. The reader receives bindings
through a bounded `RIELAENV1` stdin frame, not runtime environment/configuration
or argv; this also avoids debug logging of exec process specifications. The
runtime process inherits only host connection/configuration variables. The
bundled `riela-gateway-guard` validates UID/GID10001, zero capabilities, readonly
root, a <=256MiB nosuid/nodev/noexec tmpfs at `/tmp`, nproc<=256 and core=0, then
sets/verifies NoNewPrivs before reading credentials and executing the reader.
The official images map `/tmp` to `/dev/shm`. The idle process has a bounded
lifetime and the container is force-deleted on success, failure or cancellation.
Custom Apple reader images must provide this guard and filesystem contract.
These settings apply to the dedicated X/Gmail reader path, not every container
add-on. Use `RIELA_CONTAINER_RUNTIME=container` or `config.runnerKind` set to
`apple-container`; the general `addon.container.runtime` value is `apple-container`.

The root filesystem is read-only with writable `/tmp`. The official Gmail image
runs as UID/GID 10001, with passwd home `/dev/shm/riela-gmail`; its reader, draft, and
sender entrypoints create that private home before invoking the pinned SDK.
The direct tmpfs path avoids symlink components rejected by secure credential locks.
This lets the SDK acquire credential lifecycle locks with inline OAuth JSON
without mounting host credentials or making the root filesystem writable.
Mounted configuration and token files must be readable by that non-root user.
On Apple Container, explicit `GMAIL_GATEWAY_CREDENTIAL_DIR` values must also use
a direct `/dev/shm/...` path rather than the symlinked `/tmp/...` path.
Networking defaults to `egress-allowed`. Gateway readers running on Apple Container add the resolver
option `--dns-option no-aaaa` for this policy. On the verified Apple Container
1.5.0 default network (one link-local IPv6 address, no global-scope IPv6 address),
Gmail's default-family lookup failed while IPv4 reached
verified TLS and HTTP; suppressing AAAA lookups restores that path without
replacing the host DNS resolver or pinning endpoint addresses. This is a policy
for the current default network, not a claim about future Apple IPv6 support.
Set `config.networkPolicy` to `denied` to disable networking; that policy retains
`--network none --no-dns` and does not add a resolver option.

The opt-in image checks can use Docker on macOS or Linux:

```bash
RIELA_TEST_LIVE_GATEWAY_IMAGES=1 RIELA_TEST_GATEWAY_RUNTIME=docker \
  swift test --filter GatewayContainerImageIntegrationTests
```

The credential-lock check uses synthetic inline credentials and denied networking;
it checks the production lock path without contacting Gmail.

Files are shared only through explicit `config.mounts`, for example:

```json
{
  "source": "credentials/gmail",
  "target": "/credentials",
  "readOnly": true
}
```

Put entries in a `mounts` array. Relative sources resolve against the workflow
working directory; targets must be absolute. Mounts default to read-only.
Apple Container requires directory sources; Docker and Podman also accept files.
Set `readOnly: false` for a directory the gateway needs to write, such as a
token store or downloaded media. Bind the gateway configuration's path to the
container target, and share any files it references separately.

Digest input is available under `payload.xGateway.data` or
`payload.gmailGateway.data`. X's outer `{ok, data}` CLI wrapper is unwrapped
there for digest compatibility. The original JSON envelope is retained under
the namespace's `response` field. Runtime kind and image are recorded under
the namespace's `runtime` field.

## Current scope

All 108 catalog entries accept the common container selection. X/Gmail reader
references use their dedicated reader images; the other built-ins use the common
worker. Existing third-party container add-ons retain their package manifest and
JSONL protocol. Workflow/node execution, resume/rerun, direct step execution, and
distributed execution all select the common resolver.

Real guest gates cover time/SDK and gateway roles, memory/KV/routines/persona
state, generated child workflows, host-loopback Kaiba, and Git commit finalization
across SQLite reopen and workflow resume. External vendor accounts, every optional
provider operation, and user-specific TCC permissions are not exhaustively tested.
Apple operations require a macOS host with its existing permissions; a Linux host
cannot supply those native APIs. CLI child workflows require their declared CLI
in a custom image. Native sandbox implementation and remaining release gates are documented separately.

Build the image, then run the opt-in guest gate:

```bash
RIELA_TEST_LIVE_BUILTIN_IMAGE=1 swift test --filter BuiltinAddonImageIntegrationTests
```

Wrike reader/writer/admin roles and all three Gmail SDK modes have offline guest
capability/credential tests. Build caches stay in the builder and are not copied
into the runtime image.

## Embedded Gmail SDK

`riela/gmail-gateway-reader`, `riela/gmail-gateway-draft`, and
`riela/gmail-gateway-sender` call the async Gmail SDK in process on macOS and
Linux. Each name pins its own capability tier. The node does not spawn a Gmail
CLI or block a Swift worker while awaiting the SDK.

Supply an explicit `GMAIL_GATEWAY_CONFIG` through `addon.env`, for example
`{"GMAIL_GATEWAY_CONFIG":{"fromEnv":"ART_GMAIL_CONFIG"}}`. The SDK reads only its
supplied environment and rejects a missing configuration instead of consulting
ambient user configuration. The file must exist at the path visible to the
execution process. A container node needs an explicit read-only config mount;
a private workflow can include the config in its image and project only the
selected inline credential variables. Credential values stay out of workflow
payloads. These SDK add-ons are separate from `riela/gmail-gateway-read` above.

## Native Apple dependency bridge

Fixed Notes, Mail, Calendar, Reminder, Clock and Notification add-ons now select
a scoped native dependency bridge on a macOS host when `container: {}` is used.
The guest runs add-on validation, rendering, response processing and output
construction; only Apple gateway API calls execute in the host process, retaining
its existing TCC identity. Runtime execution identities are still carried by the
original worker protocol. The selected add-on determines allowed GraphQL root
fields and operation kind. Mutating grants permit one native operation.

The bridge uses bounded request/reply files in a per-invocation directory beneath
`.riela/addon-container-state/bridges`. Directory descriptors pin the host's reads,
writes and cleanup, and request symlinks and hardlinks are rejected. No guest
request can provide a host environment or generic shell command. The bridge is
removed after execution. A Linux host cannot supply macOS Apple APIs.

The real Linux worker transport is verified through Apple Container with scoped
host fixtures; a native schema query also uses the linked host SDK. Note body and
Mail text/HTML/raw/attachment publication pass through the real guest and a scoped
host file fixture. A native FileStore invalid-key gate checks that SDK failures
remain failures. These tests do not grant TCC permissions or access real Notes/Mail.

General Apple gateway administrative references now derive their one permitted
command from the original workflow inputs. The broker accepts that exact command,
then maps config/query/variable/output paths through the workspace and explicitly
configured mounts. Read-only mounts cannot be used as output locations, including
mounts nested under the writable workspace. Existing-parent path resolution also
rejects a workspace symlink leading outside an exposed root when the final file
does not exist. Administrative schema and file download paths have real guest
gates; host-mutating commands are checked with scoped fixtures.


Administrative query/variable files are now opened through no-follow directory
walks and passed to the SDK as inline text. Config files are bounded snapshots
on anonymous descriptors retained through the SDK call. Replacement of the
original file cannot redirect a later SDK read or grow the snapshot.

Note body and Mail file dependencies may download only keys returned by the
successful native query in that invocation. Native output is staged outside
exposed guest roots, then streamed into a pinned destination directory with
exclusive, no-follow file creation. Returned path fields are translated to the
guest mount location. This avoids relying on directory descriptor path traversal,
which is not supported by macOS `/dev/fd`. A real guest test verifies Note body
materialization through an explicit writable mount; Mail file variants and native
FileStore failure propagation are covered separately.


The common image now builds Google Analytics gateway from its pinned source,
with build-copy adaptations for Linux POSIX sockets/stat timestamps and Swift
Crypto. The SDK reader/writer/admin libraries compile on Linux. The Riela adapter
now composes reader definitions into writer, and reader/writer definitions into
admin, matching the gateway's own CLI entrypoints. The real guest tier/credential
gate verifies this composition without contacting a provider.


The build definition also stages the pinned Google Documents SDK for Linux
(Docs/Sheets/Drive reader and writer). Its build-copy adaptations add Swift
Crypto, FoundationNetworking/CoreFoundation and a bounded loopback-only POSIX
OAuth receiver, while retaining the original Network/AppKit path on macOS.
Browser opening is optional and requires xdg-open when requested on Linux;
workflow nodes continue to refuse interactive auth login/revoke commands.

Use `RIELA_TEST_BUILTIN_IMAGE=<tag>` with the opt-in image suite to inspect a
preview without replacing the default tag. The new six-role Documents dry-run
gate asserts that credentials are not loaded and provider transport is not
called. All six roles passed in the Linux guest.

## SDK execution verification

The four HTTP SDK workers (`codex-sdk-worker`, `claude-sdk-worker`,
`gemini-sdk-worker`, and `cursor-sdk-worker`) have passed a real Apple Container
gate with external networking disabled. A test-only Swift HTTP provider runs on
guest loopback. Requests to all four provider routes and the returned worker text
are asserted. This verifies the guest SDK execution path, not authenticated vendor
services or arbitrary shell tools.

Build and run the independent test image after building the common worker:

```bash
container build --cpus 4 --memory 8G -t riela-provider-fixture:local \
  -f containers/provider-fixture/Containerfile \
  --build-arg WORKER_IMAGE=riela-builtin-addons:local .
RIELA_TEST_LIVE_PROVIDER_IMAGE=1 swift test \
  --filter BuiltinSDKContainerIntegrationTests
```

Use Xcode's arm64 Swift toolchain on Apple Silicon. The fixture image contains a
loopback-only server and entrypoint wrapper; neither is in the production worker
image. Plain HTTP provider URLs remain restricted to loopback by the SDK's
existing provider validation.

## Document converter build dependency

The common image builds the pinned `anydoc-swift` Rust static library using its
Cargo lockfile, then links `AnydocKit` into the Swift worker. Rust, Cargo,
pkg-config, and converter source stay in build stages. Native Linux source builds
must provision that static library and set `PKG_CONFIG_PATH` to its pkg-config
directory before invoking SwiftPM. The container build does this automatically.

## Kaiba instance capture

A containerized Kaiba add-on receives only the named/default instance captured by
runtime preflight. The guest never reloads the host's instance catalog. The
execution request contains the stable instance ID, endpoint, credential environment
name, and connection policy; it contains no credential value. The selected
instance's credential binding is forwarded automatically, and an explicit binding
that disagrees with it fails before container launch. Other instances' credentials
are not forwarded. The guest repeats the readiness/capability checks against this
captured selection before business work.

Remote endpoints must be reachable from the guest. Host-loopback instances use a
dedicated file RPC transport to the captured host endpoint, with fixed POST headers,
no redirects, bounded request/response sizes, and execution deadlines. The guest
cannot supply a different destination or Authorization header. The configured
credential remains on the host unless the author explicitly also forwards it in
`addon.env`. GraphQL error diagnostics are redacted with the host SDK's credential
redactor before transport. This declared host-service RPC remains available with
guest networking denied; it does not enable general host networking.

The real guest capture fixture is opt-in through
`RIELA_TEST_LIVE_BUILTIN_IMAGE=1` and BuiltinSDKContainerIntegrationTests, using the
common worker image selected by `RIELA_TEST_BUILTIN_IMAGE`. It runs a host-loopback
HTTP fixture and verifies readiness, the business query, and host authentication.

## Declared tools and workflow children

The default image supplies compiled Swift SDKs, Git, and OpenSSH. It does not
supply vendor agent CLIs or Node.js. For workflow-create-register-run, choosing a
CLI executionBackend requires a custom container image with that CLI and its
runtime dependencies, just as native execution requires that CLI on the host.
HTTP SDK execution backends avoid those dependencies.

The provider fixture image additionally contains a minimal fake Codex CLI solely
to test generated child workflow registration and execution without contacting a
vendor. It must not be used as a production agent image. Real guest stateful tests
are available through BuiltinStatefulContainerIntegrationTests; they cover all four
memory operations, KV CRUD, routines, persona routing/memory, reply intent,
handover envelopes, and digest state reads.

## Native service configuration boundary

Apple bridge requests retain the host service's configured cache, Mail root,
notification helper, domain policy, and audio device selection. A guest TOML
configuration may change request limits, but cannot replace those host-owned
settings. Configuration inputs are snapshotted before validation and invocation.
The host configuration, service cache, and any explicitly configured notification
helper must stay outside every guest share (including a share beneath that
cache). Final file downloads without an outputDir go to the workspace's
`tmp/apple-gateway/downloads`, through the same private staging and publication
checks as explicitly selected destinations.

Running an already compiled Swift worker needs runtime libraries, not the Swift
compiler or SDK. Executing AI-generated `.swift` source also needs a compiler and
SDK somewhere; a native process sandbox can reuse the host installation with
read-only access rather than duplicating it in every container image.

## Focused verification

From an arm64 shell with Xcode's Swift toolchain selected, the production image
gates use these explicit opt-ins (all endpoints and credentials are fixtures):

```bash
RIELA_TEST_LIVE_BUILTIN_IMAGE=1 \
RIELA_TEST_BUILTIN_IMAGE=riela-builtin-addons:local \
RIELA_TEST_LIVE_PROVIDER_IMAGE=1 \
RIELA_TEST_PROVIDER_IMAGE=riela-provider-fixture:local \
swift test --filter 'BuiltinAddonImageIntegrationTests|BuiltinStatefulContainerIntegrationTests|BuiltinGitContainerIntegrationTests|BuiltinContainerEntryPointTests|AppleMailContainerIntegrationTests|BuiltinSDKContainerIntegrationTests'
RIELA_TEST_LIVE_GATEWAY_IMAGES=1 swift test --filter GatewayContainerImageIntegrationTests
xcrun swiftlint lint --quiet --no-cache <changed-swift-files>
```

Use matching CPU/memory settings for sequential Apple Container builds: changing
the shared builder VM's resource settings can restart it and interrupt another
build. Compiler base images and the builder's disk can be removed after image
verification when faster rebuilds are less important than local disk space.
