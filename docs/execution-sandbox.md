# Execution sandbox backends

Riela supports container, macOS Seatbelt, and Linux bubblewrap selection for the
Swift worker and its children. Actual gates cover all seven vendor CLI/SDK paths
on macOS, Linux, and the container transport, including read-only host credentials.
Final integration verification passed 59 focused tests, the actual Linux backend
gates, and both default-image CLI smoke checks.
Existing `addon.container` execution remains supported.

## Native command execution

```sh
riela sandbox run --backend seatbelt --working-dir /absolute/workspace \
  --credential-path /absolute/private/provider-auth \
  -- /absolute/tool argument
```

`auto` selects Seatbelt on macOS and bubblewrap on Linux. It never falls back to
unrestricted execution. `container` selects Apple Container, Docker, or Podman
using the existing runtime discovery. `--options` accepts the common JSON config
or an `@file`; explicit flags add read/write/credential paths and environment names.
`--allow-network` enables IP egress. Without it, network access is denied.
Commands are foreground, non-interactive executions with a default 120-second
limit (`--timeout-ms` overrides it). Child exit failures produce a Riela failure.

The working directory is writable; the filesystem root cannot be used as the
workspace or a share. Relative container mount sources are resolved against that
working directory before checking for writable aliases of credentials.
Other user data is hidden unless explicitly
shared. System runtime files and the selected executable are readable. Native
shares reject user-controlled symlink traversal, rather than broadening grants to
whatever a previous guest has pointed a path at. Metadata and exact ancestor
directory entries needed for macOS startup/getcwd are readable.

Each invocation receives private temporary storage. Vendor CLI nodes retain a private
HOME for session reuse within the workflow run and remove it when the run ends.
Ambient host environment variables are not inherited. Native PATH and locale
settings, explicit
`--env NAME` selections, and resolved node `agentEnvironment` values are forwarded.
Container commands use the image PATH by default and need not exist on the host.
An explicit `--env PATH` or node environment binding can override it.
Loader injection variables and runtime-owned HOME/tmp/state names are refused.

Credential paths must exist outside every writable share. `credentialPaths` are
readable at their original absolute paths. For the vendor's usual HOME location,
use `credentials` instead:

```json
"credentials": [
  {"source": "/absolute/private/auth.json", "homePath": ".vendor/auth.json"}
]
```

Only selected files are copied into a bounded read-only snapshot and linked into
the private HOME. Binary files are supported; nested symlinks and special files
are refused. The guest cannot update the snapshot or the host original, including
when the vendor tries to refresh authentication. This grants no Keychain or
SSH-agent access. The directory-backed projection was verified with individual
credential files on Apple Container, which requires directory mount sources.

## Vendor agent nodes

A file-backed agent node can declare an OS boundary independently of its vendor's
`agentSandbox` permission option:

```json
{
  "id": "worker",
  "executionBackend": "official/openai-sdk",
  "model": "your-model",
  "workingDirectory": "/absolute/workspace",
  "sandbox": {
    "backend": "seatbelt",
    "networkPolicy": "egress-allowed",
    "environment": ["OPENAI_API_KEY"]
  }
}
```

The same typed object can be saved in an instance's `nodePatches`, or selected
for one workflow run:

```sh
riela workflow run your-workflow \
  --node-patch '{"worker":{"sandbox":{"backend":"seatbelt","networkPolicy":"egress-allowed"}}}'
```

Run overrides replace the saved sandbox object, including its access lists. `sandbox` is separate
from the vendor CLI's `agentSandbox` permission flag.

The production node adapter sends a bounded, versioned request to a separate Swift
worker. The worker hosts the linked gateway, so HTTP SDK calls and CLI subprocesses
are inside the selected boundary. Runtime execution identities are passed unchanged;
output/usage and backend event records return over JSONL. No runtime IDs are minted
by this transport. Every current vendor backend selects this path: Codex, Claude
Code, Cursor CLI, and the OpenAI, Anthropic, Gemini, and Cursor HTTP SDKs.

Actual macOS, Linux, and container gates cover all three vendor CLIs with protocol
fixtures and all four HTTP SDKs with local provider endpoints. CLI tests verify read-only credential
projection, private HOME reuse, session identity, events, and cleanup. Reuse refuses
changes to isolation policy or provider settings. Vendor session reuse is scoped
to the workflow run, matching the existing in-memory AgentGatewaySessionStore;
restoration across a new adapter/process is not provided. Runtime SQLite session
and execution identities remain owned by the runtime. The source-built worker
image includes the node-worker entrypoint. Vendor CLIs require a custom image
containing their Linux executables and dependencies.
Native CLI nodes similarly need explicit read access to their existing executable
installation and language runtime, if used by that vendor. Riela's Swift worker
and HTTP SDK paths introduce no Node or Python runtime dependency.

Built-in add-ons accept the same object as `addon.sandbox`. Standalone execution
also accepts `--sandbox` and `--sandbox-options JSON|@file`:

```sh
riela node run riela/time-signal --sandbox seatbelt \
  --working-dir /absolute/workspace \
  --variables '{"scheduledAt":"2026-10-15T00:30:00Z","timezone":"UTC"}'
```

This command has been verified through the native Swift add-on worker. Acceptance
and terminal callbacks retain the persisted transport. A real Git commit followed
by SQLite reopen/resume and dropped-acknowledgment reconciliation passed on Seatbelt. `--container` and `--sandbox` cannot be combined. Legacy
X/Gmail reader images require container isolation and explicitly refuse native
selection. Direct low-level gateway/add-on/stdio calls refuse an unhandled sandbox
declaration instead of silently executing on the host.

The macOS policy includes system timezone data needed by Foundation date formatters.
Opt-in IP egress also permits the specific system DNS resolver socket; external
DNS/TLS was verified with `curl`. For Xcode-hosted tools, share their installation
explicitly. The add-on worker uses the trusted Git binary inside Xcode/Command Line
Tools directly, so Xcode must be shared when running native Git add-ons.

## Running generated Swift without a compiler image

On macOS, an existing Xcode toolchain/SDK can be shared read-only:

```sh
riela sandbox run --backend seatbelt --working-dir /absolute/swift-workspace \
  --read-path /Applications/Xcode.app/Contents -- /bin/sh -c \
  'exec /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -module-cache-path "$TMPDIR/modules" hello.swift'
```

This source execution was verified with Foundation imported. Xcode's shared
frameworks live outside `Contents/Developer`, so that narrower path alone is not
enough for the Swift driver. Compiler subprocesses inherit the same OS restrictions;
compiler caches go into private temporary storage, not the host developer cache.

## Linux policy

On macOS the backend uses the existing `/usr/bin/sandbox-exec`; no additional
runtime package is required. On Debian/Ubuntu, install the single isolation tool:

```sh
sudo apt-get install --no-install-recommends bubblewrap
```

The kernel must allow unprivileged user namespaces. No Node/Python dependency is
introduced for Linux isolation. Python used by the integration fixtures is only
a verification tool in a disposable VM.

The bubblewrap plan constructs an empty filesystem, binds explicit shares, creates
user/PID/IPC/UTS/network namespaces, disables further user namespaces and drops all
capabilities. IP egress is opt-in. A seccomp filter prevents host Unix-socket access
including abstract sockets when the network namespace is shared. Only IPv4/IPv6
socket creation and anonymous Unix stream socketpairs are allowed; reconnectable
Unix datagram pairs and io_uring socket bypasses are denied. The emitted filter's
architecture and branch behavior have unit tests. Actual Linux execution as an
unprivileged user passed filesystem, child, credential, environment, IP and Unix
IPC denial gates, plus all SDKs and CLI workflows. System path aliases such as
/bin and /lib are reproduced from already-approved read-only sources so ELF
loaders and resolver/timezone paths remain available in the empty root.
Unsupported kernels or missing bubblewrap fail the selected run. A restrictive
outer container can prevent nested /proc mounts; the disposable Linux test VM
cleared only its outer proc restrictions while bwrap still dropped all caps.

## Runtime footprint

The default common image contains one stripped Swift executable and a small
add-on worker entrypoint. It has no Swift compiler, Node or Python executable.
The verified arm64 image is 120,359,567 bytes compressed; a disposable VM measured
356,064 KiB for its execution root. Compiler toolchains, Rust and build-only
Python/pkg-config are confined to build stages. Native macOS execution adds no
container image; generated Swift can use the installed read-only Xcode toolchain.

## Verification commands

Use Xcode's arm64 Swift toolchain on Apple Silicon:

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test \
  --filter 'NativeProcessSandboxTests|NativeSandboxNetworkTests|NativeSandboxSeccompTests|SandboxedVendorNodeTests|WorkflowExecutionSandboxTests|BuiltinAddonContainerProtocolTests'
xcrun swiftlint lint --quiet --no-cache <changed-swift-files>
```

For the opt-in Apple Container vendor matrix, use a source-built worker image.
The SDK fixture uses a test-only loopback TCP proxy so provider validation retains
its restriction against non-loopback HTTP endpoints. Its helper is exported from
a disposable VM; neither socat nor Python is added to the production image.

```sh
proxy_dir=$(sh Tests/Fixtures/execution-sandbox/prepare-sdk-proxy.sh riela-builtin-addons:local)
RIELA_TEST_SANDBOX_CONTAINER_IMAGE=riela-builtin-addons:local \
RIELA_TEST_CONTAINER_HOST=192.168.64.1 \
RIELA_TEST_SDK_PROXY_DIRECTORY="$proxy_dir" \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test \
  --filter 'SandboxVendorSDKTests|SandboxVendorSessionTests'
```

`RIELA_TEST_CONTAINER_HOST` is the host address reachable from the test VM; the
shown value is the gateway observed in this Apple Container environment. These
fixtures use synthetic credentials and local provider endpoints.

The Linux enforcement gate can also run in a disposable Apple Linux VM. The
outer VM grants below permit nested proc/user namespaces; the tested worker runs
as `nobody`, and bubblewrap drops all capabilities inside its own boundary.

```sh
container run --rm --cpus 2 --memory 2G --cap-add SYS_ADMIN \
  --masked-path NONE --read-only-path NONE \
  --mount "type=bind,source=$PWD/Tests/Fixtures/execution-sandbox,target=/gate,readonly" \
  --entrypoint /bin/sh riela-builtin-addons:local -c \
  'set -eu; apt-get update >/dev/null; apt-get install -y --no-install-recommends bubblewrap python3 >/dev/null; su -m -s /bin/sh nobody -c "python3 /gate/linux_gate.py && python3 /gate/linux_sdk_gate.py && python3 /gate/linux_cli_gate.py"'
```
