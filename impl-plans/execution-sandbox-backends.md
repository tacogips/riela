# Execution sandbox backends

Status: implementation, verification, promotion, and task-owned cleanup complete
(2026-10-15).

## Requirements and implementation

Riela can select container, macOS Seatbelt, or Linux bubblewrap for a separate
Swift worker and all of its descendants. The typed sandbox configuration applies
to all seven vendor CLI/SDK backends and built-in add-ons. Generic sandbox command
execution also supports generated Swift using a read-only host toolchain.

- Configuration is validated, Codable, and supported by workflow instance node
  patches and run overrides. Unsupported/missing selected backends fail closed.
- Native filesystem access is allowlisted, workspace writes are explicit, HOME
  and temporary directories are private, and host environment inheritance is off.
- Host credentials are selected explicitly and exposed read-only. HOME projections
  use bounded snapshots and pinned/no-follow installation, outside writable shares.
- IP networking is denied by default. Linux bubblewrap creates namespaces, drops
  capabilities, prevents nested user namespaces, and filters host Unix IPC and
  io_uring bypasses with seccomp. System aliases retain approved read-only roots.
- The versioned JSONL worker protocol preserves runtime-owned execution/session
  identities, output, usage, and vendor events. CLI private HOME/session reuse is
  scoped to one workflow run, matching the baseline in-memory session store.
- Production adapter entry points use the wrapper. Low-level calls refuse
  unhandled isolation declarations. Add-on acceptance/finalization/resume retain
  the chosen transport and scoped native service bridge authority checks.
- Container execution preserves the image PATH unless explicitly overridden and
  permits programs installed only in the image. Root workspace/share aliases and
  writable credential aliases are rejected before launch.

The native paths introduce no Node/Python runtime dependency. Existing vendor
CLIs still require their own installation/runtime, shared explicitly on native
hosts or installed in a custom container. Legacy X/Gmail reader images are
container-only and refuse native selection. No cross-process vendor-session
persistence was added; runtime SQLite identity/lineage stays runtime-owned.

## Final verification evidence

The frozen task verification checkout avoided concurrent unrelated Memory and
Workflow evolution edits while testing the matching sandbox implementation.
The following terminal results were confirmed, not inferred from quiet logs:

| Gate | Result |
| --- | --- |
| Final arm64 Linux release image build | Exit 0; index `56fa7898d775e66df5d9c440bac7e9344503ef5e8127f8f2087187d972c284ed` |
| Actual Linux filesystem/child/credential/env/IP/Unix IPC enforcement | Passed as unprivileged nobody inside bubblewrap |
| Actual Linux SDK and CLI workflows | All 4 SDKs and 3 CLIs passed |
| Combined native/container configuration, credential, vendor, add-on and Git reopen gates | 59 tests, zero failures/skips, exit 0 |
| Default image `node run riela/time-signal --sandbox container` | Exit 0; JSON status ok |
| Default image `sandbox run --backend container -- riela --help` with minimal host PATH | Exit 0; executable resolved only in image |
| Focused SwiftLint | Earlier comprehensive 42-file pass; final 35 native/sandbox-related files passed after latest edits |
| Whitespace | git diff --check passed |

Earlier live evidence also confirmed installed Codex, Claude, and Cursor CLI help
inside Seatbelt; Foundation source compilation with read-only Xcode; external
DNS/TLS opt-in; native Git commit and SQLite reopen/dropped-ack reconciliation;
and legacy container stateful/lifecycle regressions. Vendor protocol tests use
synthetic credentials and local HTTP provider fixtures; no real model billing.

## Minimal artifact and cleanup

The promoted default image `riela-builtin-addons:local` has variant
`089ed9e8f9152a0e370e4d4b990a36681ef85eeae775bc162d1984e1aa3b08d3`.
It is 120,359,567 bytes compressed; measured execution root is 356,064 KiB,
including 40,940 KiB /opt/riela and 77,080 KiB Swift shared libraries.
One stripped Swift executable and a tiny worker entrypoint replace duplicate
executables. Swift compiler, Node and Python executables are absent. Compiler,
Rust and Python build dependencies remain build-stage-only. Native macOS needs
no image or additional runtime package; Linux needs bubblewrap and usable user
namespaces.

Both default CLI smokes passed BEFORE cleanup. The task-owned builder and compiler bases/temporary image references were
removed; image deletion reported 3.3 GB reclaimed, in addition to deleting the
builder cache. The 2.5 GB tmp/execution-sandbox verification checkout, logs and
fixtures were removed. The promoted local image, preexisting reader images,
ubuntu, vminit, root .build, and unrelated user changes remain. No global prune
was used. Container inventory is empty after cleanup.

Usage, limitations and reproducible verification commands are in
[docs/execution-sandbox.md](../docs/execution-sandbox.md). Test fixture scripts
under Tests/Fixtures/execution-sandbox remain as reusable regression tooling.
