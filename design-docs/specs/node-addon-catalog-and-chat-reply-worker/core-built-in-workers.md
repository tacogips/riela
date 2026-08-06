# Node Add-on Catalog and Built-in Workers: Core Built-in Workers

## Built-in Git Finalization Add-ons

`riela/git-commit@1` and `riela/git-push@1` are runtime-owned workflow
finalization add-ons. The built-in resolver requires the explicit version
`"1"`; an omitted or different version is policy-blocked. An authored node
must independently opt into each mutation with
`config.allowCommit: true` or `config.allowPush: true`. Workflow progression or
an earlier approval does not implicitly authorize either operation. The
`codex-design-and-implement-review-loop` places these nodes after review,
documentation, plan-completion, and commit-message generation gates.

### Commit boundary and data flow

The commit node renders `commitMessageTemplate` and `committedFilesTemplate`
from its workflow variables. The message must resolve to a trimmed, non-empty
string of at most 4,096 UTF-8 bytes without NUL. The committed-files value must
resolve to an array of 1 through 2,048 unique strings; coercing a scalar or
accepting an omitted value would weaken the Step 9 contract.

Each committed path must be repository-relative and must not contain an empty,
`.` or `..` component, a leading slash, a `.git` first component, NUL, CR, or
LF. The resolved working directory must exactly equal the resolved Git
top-level directory. Every entry identifies one exact tracked or untracked
non-directory worktree path; an exact tracked deletion is also valid.
Directories and implicit descendant expansion are rejected so a broad entry
cannot absorb unrelated work. Every path-bearing Git invocation runs with
literal pathspec semantics. Inputs that use Git's leading-colon pathspec-magic
form are rejected before invocation; wildcard characters in legitimate file
names remain literal. Immediately before hashing, each path component is opened
without following links and the final entry is opened nonblocking; descriptor
validation rejects a raced symlink, FIFO, or other non-regular replacement
without waiting outside the workflow deadline.
For a tracked regular path, prepared-index staging follows Git's effective
`core.filemode` behavior: when executable-bit tracking is disabled, the
existing regular-file executable mode is preserved rather than inferred from
worktree permission bits. A tracked symlink mode is preserved for a regular
worktree representation only when effective `core.symlinks` is disabled;
otherwise replacing a symlink with a regular file records the regular-file
mode. Author- and committer-specific identity configuration retains its normal
precedence over `user.name` and `user.email`, and each resolved value is
snapshotted independently before commit creation.

Before staging, the add-on opens the canonical index with no-follow and
nonblocking flags, proves through the descriptor that it is the bounded,
single-link regular file whose device and inode were captured during preflight,
and reads only through that descriptor while enforcing the workflow deadline.
It records the resulting fingerprint and rejects any staged path that is not an
exact allowlist entry. A symlink, FIFO, or identity swap before an initial or
retry read fails closed without following or blocking on the replacement.
An index lock present during preflight blocks execution before reference
mutation; a lock created after preflight is handled by the publication rules
below.
It does not hold or reuse `.git/index.lock` while staging. Instead, it copies the
canonical index into an attempt-scoped file in the runtime-owned finalization
store outside the repository. Staging and validation operate only on that
temporary index. Validation failures, partial Git failures, and policy blocks
discard an unjournaled temporary index and leave the canonical index
byte-for-byte unchanged. It refuses an empty commit. Unstaged and untracked
paths outside the allowlist remain untouched.

After verifying the temporary staged set against the exact allowlist, the
add-on prepares the tree and commit object without moving `HEAD`. Before any
reference mutation, it durably journals the original branch ref and parent
object id, expected tree and candidate commit object ids, validated message and
identities, authored allowlist, original and prepared index fingerprints, and
the prepared index location and a random runtime-owned operation token.

Publication acquires `.git/index.lock` with exclusive creation before changing
the branch. A lock that already exists is never removed, replaced, or classified
as stale by the add-on; execution returns a retryable lock-conflict failure and
retains the journal. The created lock descriptor remains open through ref and
index publication or owned cleanup, preventing inode reuse from disguising a
replacement. While holding that lock, the add-on proves that its descriptor and
path still identify the same single-link regular file and that the canonical
index still has the journaled original
fingerprint, writes and synchronizes the prepared index bytes to the lock, then
advances the branch from the recorded parent to the candidate with a
compare-and-swap ref update. The ref update uses `--create-reflog` and creates a
reflog entry containing the unguessable operation token even when repository
reflog creation is disabled and the branch has no existing log. The add-on
immediately verifies that newest exact parent-to-candidate entry before index
publication. A concurrent `HEAD` change fails the
compare-and-swap without overwriting that change. Only after the ref update does
the add-on atomically rename the held lock to `.git/index` and synchronize the
Git directory. Before process death, cleanup may remove only a lock whose open
file identity is still owned by that process; after process death, automatic
lock deletion is forbidden.

Retry reconciliation is a deterministic state machine. The journaled parent
plus original index may resume ref advancement only when the branch reflog has
no update carrying the journaled token. Candidate `HEAD` plus the original index
may resume index publication only when the reflog proves the exact token,
parent, and candidate update. Candidate `HEAD` plus the prepared index and that
same reflog proof means the commit is complete. A tokened update followed by a
reset or any other `HEAD`, reflog, or index state is policy-blocked, so retry
does not overwrite a deliberate concurrent ref movement. An existing
`.git/index.lock` always remains a retryable external conflict, including when a
prior crashed process may have created it. After operator or owning-process
resolution of that lock, retry recreates the prepared lock from the journaled
file and resumes the proven state without creating another commit. A missing or
corrupt prepared index, missing reflog proof after ref advancement, journal
mismatch, or ambiguous state fails closed.
Missing, malformed, or integrity-invalid immutable journal and predecessor-link
records are bounded, path-free, non-retryable policy failures. Other Foundation
filesystem failures remain bounded, path-free, retryable provider failures.

### Execution identity and journal lifecycle

The runtime records the step execution before calling a mutating add-on and
passes a runtime-owned identity containing `workflowExecutionId`, the unique
`stepExecutionId`, monotonic `attempt`, and an optional exact predecessor
execution id plus the ordered ids of every consecutive unaccepted predecessor
for a retry. `WorkflowAddonExecutionInput` and the deterministic runner-to-resolver
boundary carry these fields; authored variables and add-on configuration cannot
set or override them. After repository and finalization-store confinement is
validated, a retry searches that bounded, runtime-owned ancestry newest-first
and may read only the first exact immutable journal link it contains. The
journal must belong to the same workflow execution, logical step, repository
identity, and rendered-input digest. The current execution then receives an
alias before journal validation or reconciliation. A predecessor that fails
during retryable repository preflight therefore cannot hide an earlier journal
or turn the following retry into a fresh commit transaction.

Repository identity combines the canonical worktree top-level, Git discovery
path, per-worktree Git directory, per-worktree index entry and parent, Git
common directory, exact common-directory binding, non-symlink object directory,
and object format with their stable filesystem identities; a regular-file
`.git` discovery path also carries a bounded content digest. The index must be
a single-link regular file directly inside the validated per-worktree Git
directory; final-component symlinks and sibling-worktree targets are rejected.
The initial `.git` entry is opened without following a final symlink and with
nonblocking semantics; when it is a regular discovery file, its bounded
`gitdir:` target must exactly equal
the per-worktree Git directory returned by both discovery passes. That
directory's bounded no-follow, nonblocking `gitdir` backpointer must
reciprocally identify the exact worktree `.git` entry; its identity and digest
are retained and revalidated before mutation. FIFO replacement of either entry
fails before a blocking read.
For a linked worktree, its bounded no-follow `commondir` file must resolve to
the recorded common directory and the per-worktree Git directory must be a
direct child of that common directory's `worktrees` directory. The binding's
device, inode, and digest are captured during both preflight passes and
revalidated before every repository Git operation and publication mutation.
The exact lexical `<common-directory>/objects` entry must itself be a directory,
not a final-component symlink; its device and inode are bound and revalidated
with the repository identity.
Repository Git commands are pinned to the validated worktree and Git directory,
and identity is revalidated immediately before ref and index publication.
Preflight repeats Git-directory, common-directory, and exact-index discovery
before publishing the repository context; both path snapshots and the `.git`
entry identity and digest must match. The rendered input digest covers the
operation, validated commit message, and ordered exact file allowlist. The
journal key is a SHA-256 digest of repository identity,
`workflowExecutionId`, `stepExecutionId`, `attempt`, and rendered-input digest;
raw paths and authored strings are never used as path components. Journal and
prepared-index writes are create-only, bounded, synchronized, and atomically
renamed. An existing byte-identical record is an idempotent replay; a key
collision with different bytes is policy-blocked. These rules isolate
concurrent sessions and prevent an earlier workflow run from authorizing a new
one.

Every immutable-record collision and recovery read opens the final entry with
`O_NOFOLLOW | O_NONBLOCK`, requires a bounded regular-file descriptor, reads
only through that descriptor under the workflow deadline, and verifies that
the path still identifies the opened inode. A post-publication crash may leave
the destination hard-linked from the runtime-owned temporary directory; retry
non-destructively validates every extra link as the opened device and inode
beneath that pinned directory, under the workflow deadline and a 4,096-entry
bound, then repeats ownership validation after the descriptor read. Crash
artifacts remain available for bounded garbage collection. Symlinks, FIFOs,
oversized files, foreign hard links, ownership replacement, and path replacement
during the read fail closed without following, deleting, or blocking on the
foreign entry.

The finalization root and each runtime-managed child directory are opened with
no-follow semantics and retained by descriptor together with their device and
inode identities. Every later store operation revalidates those pathname
bindings before using descriptor-relative creation, permission changes,
linking, reads, scans, synchronization, or removal. Replacing the root or any
managed directory with a symlink after preflight therefore policy-blocks the
operation without following the replacement or mutating its target.

Failed-artifact garbage collection scans each runtime-owned directory through a
no-follow descriptor under the workflow deadline and a 4,096-entry bound. An
eligible regular file is opened and snapshotted, revalidated after any
concurrent change window using the same cutoff-qualified snapshot, atomically
moved into a new private quarantine directory, and deleted only when the
quarantined descriptor still has the exact device, inode, mode, link count,
size, and modification time. A replacement is restored to its original name
through an exclusive rename when that name remains free; otherwise it stays
isolated rather than being overwritten or deleted. Cleanup-limit accounting
counts only entries actually removed.
Age alone never authorizes journal removal. After the runtime durably records a
completed session or a non-resumable failed session, it supplies the persisted
workflow and step-execution identities through the add-on finalization
boundary. The Git resolver binds those identities to its validated repository
identity and writes a create-only marker for each exact matching journal. A
max-step failure remains resumable and is not marked terminal. Commit and push
preparation may run bounded age-based collection, but only journals with a
matching valid terminal marker are eligible; active or crash-interrupted
unaccepted retry ancestry remains retained. Each marker is removed after its
journal is collected. Orphan temporary entries remain
eligible under the existing age, identity, deadline, and entry-count bounds.

The finalization store is runtime-owned session persistence outside the Git
repository, not repository-root `tmp/` and not workflow-selected storage. The
add-on returns a runtime-internal journal token alongside its normal output.
After accepted output is durably published, the runner marks that exact token
accepted and may remove its journal and prepared index. Cleanup failure does not
revoke accepted output: startup reconciliation compares the token with the
durable accepted step output before cleanup. A journal without accepted output
is retained for explicit retry or bounded failed-session garbage collection;
garbage collection never changes Git refs, indexes, or locks.

### Push boundary and data flow

The push node renders the accepted Step 10 `commitHash` through its explicit
`expectedCommitHashTemplate`, requires a full object id, and fails before live
remote access when the current `HEAD` does not equal that authorized commit.
It then resolves a named current branch and its configured upstream.
Branch names must be valid `refs/heads/` names, contain no control characters,
and be at most 1,024 UTF-8 bytes. Rather than parsing a display-form
`remote/branch` string, the add-on snapshots `branch.<branch>.remote` and
`branch.<branch>.merge`. The remote name must be 1 through 255 ASCII bytes,
match `[A-Za-z0-9][A-Za-z0-9._-]*`, be neither `.` nor `..`, and not end in
`.lock`. These rules exclude slashes, whitespace, control characters, leading
hyphens, and configuration-key delimiters. The merge ref must exactly equal
`refs/heads/<current-branch>`. Detached `HEAD`, a missing or mismatched value,
or a branch behind its local upstream-tracking ref is policy-blocked before
network mutation. Only after validating these independent values may the
runtime construct configuration lookup keys or the local tracking-ref name.
It expands the configured push URL, validates that effective value, and uses
that validated snapshot rather than re-resolving a mutable remote name.

Accepted version `1` transports are explicit HTTPS URLs without user
information, SSH URLs without passwords, and SCP-style SSH locations without
embedded secrets. Absolute local and `file://` transports are policy-blocked:
a local receive-pack executes destination-owned hooks and configuration under
the Riela process user, and client-side hook overrides do not confine that
receiver. External-helper syntax such as `ext::`, unknown URL schemes, URL
rewrite results outside the accepted network forms, credential-bearing URLs,
and configured receive-pack commands are rejected. When the branch is ahead,
the add-on requires the accepted commit to have exactly one parent, requires
that parent to equal both the tracking revision and live remote tip, and
requires the local ahead count to be exactly one. It then pushes `HEAD` to
`refs/heads/<current-branch>` using a non-force refspec, preventing older
unreviewed local commits from being published. Transport values are parsed
structurally; control or whitespace
characters, URL query or fragment data, and option-like SSH host components
are rejected. Deterministic tests may inject a local-fixture transport policy,
but production version `1` cannot opt into it through workflow or repository
configuration.
HTTPS authority and path validation applies after percent-decoding. Decoded
control or whitespace characters and malformed or out-of-range ports are
policy-blocked before credential-helper or network access.

### Invocation, retry, and diagnostics

Production executable selection is a runtime policy boundary. Version `1`
selects Git only from the exact system path `/usr/bin/git`; it never searches
the process `PATH`, accepts a workflow- or repository-provided executable, or
uses `/usr/bin/env`. The runtime resolves symlinks before first execution and
requires the canonical target to be outside the repository, owned by root, and
writable only by root. Each parent must be owned by root and writable only by
root or the platform's system-administrator group; world- or untrusted-group
writable paths are rejected. This makes the local system administrator, but not
the process `PATH` or repository owner, the version `1` installation trust
boundary. A missing or nonconforming executable is policy-blocked.
Additional installation roots require an explicit versioned runtime policy and
deterministic tests; environment variables and Git configuration cannot extend
the allowlist. Tests may inject a command runner without changing production
selection policy.

Production resolves the approved Git executable once and invokes that canonical
file directly for every Git operation. The runner constructs a minimal
environment, preserves only explicitly required non-Git values, and removes
inherited `GIT_*` command, repository, index, configuration, object-store,
SSH-command, proxy-command, askpass, and pager overrides. The runner then sets
its own literal-pathspec and temporary-index values. System, global, and
repository configuration may be queried during a read-only preflight, but
finalization commands receive only validated snapshots of required identity,
branch, upstream, remote, and credential data plus explicit safety overrides.
Every invocation also uses Git's global `--no-replace-objects` option.
Repository `refs/replace/*` values therefore cannot substitute a different
`HEAD` tree for canonical-index allowlist comparisons, empty-commit checks,
retry evidence, or push ancestry. Legacy grafts were reviewed separately: they
do not substitute tree content and cannot hide an allowlist-external index
entry from the exact tree comparison fixed here.

Author and committer identities are resolved during preflight using Git's
normal configuration precedence, bounded, and rejected if empty or containing
NUL, CR, or LF. The validated values are passed explicitly to the commit
process, so finalization does not depend on mutable configuration after
preflight. HTTPS authentication follows the same snapshot rule: each effective
credential helper must resolve to one canonical absolute executable outside the
repository from the trusted Git installation or an approved system location.
Shell snippets, helper arguments, relative paths, repository-contained helpers,
and unresolved helpers are rejected. Finalization clears the inherited helper
list and supplies only the validated absolute helper list in its original
order; credentials remain on the helper protocol stream and never enter
arguments, URLs, output, or diagnostics.

For version `1`, the trusted Git installation helper root is the canonical
directory reported by the approved Git executable through `--exec-path`, after
inherited `GIT_EXEC_PATH` and other `GIT_*` overrides have been removed. The
root and every parent directory must satisfy the same trusted ownership and
write-permission checks as the Git executable. Any Git transport helper used by
the accepted URL schemes must be a regular executable canonically beneath that
root and pass those checks. A credential helper named by Git configuration is
resolved only as `git-credential-<name>` beneath that root.
An absolute configured helper is accepted only when its canonical file is
beneath that root. The sole host-policy exception is the exact canonical macOS
system helper `/usr/bin/git-credential-osxkeychain`; version `1` does not trust
a general system-directory or `PATH` search. Every accepted candidate must be a
regular executable file, must remain outside the repository after symlink
resolution, and must match one of those canonical locations. If no candidate
matches, HTTPS push is policy-blocked. Other platforms or helper locations
require an explicit runtime policy change and deterministic resolution tests;
workflow input and repository, global, or system Git configuration cannot
expand the trusted locations.

Every invocation uses explicit safety configuration: repository hooks point to
a runtime-owned empty directory, filesystem monitoring is disabled, commit and
push signing are disabled, terminal credential prompting is disabled, and
allowlisted paths with an effective custom clean filter are rejected before
staging. This prevents repository or user Git configuration from introducing
an unreviewed command between confinement checks and mutation. Supported SSH
transport may use an existing agent only through the exact canonical
`/usr/bin/ssh` executable after the same ownership, permission, symlink, and
repository-exclusion checks. The runtime passes that validated absolute path as
its own SSH executable override; inherited or configured SSH command strings
are rejected. If that executable is unavailable, SSH transport is
policy-blocked without falling back to `PATH`.

Both add-ons pass Git an argument array, place `--` before path arguments, and
never construct or evaluate shell command strings. Captured Git output is
bounded to 1 MiB and must be valid UTF-8. Provider failures are retryable but
expose only the exit code through the workflow error boundary, so remote URLs,
credentials, and command output are not copied into workflow diagnostics.
Filesystem and persistence failures are also converted at the Git add-on
boundary to bounded, path-free runtime diagnostics; raw Foundation error
descriptions are never published to workflow state.

The push add-on discovers and validates the source repository object format as
exactly `sha1` or `sha256`. Its runtime-owned isolated bare transport repository
is initialized with that same explicit format before its alternates file is
bound to the identity-checked source object directory. This keeps 64-character
SHA-256 source object ids valid through isolated `update-ref` and push without
allowing Git's platform default format to change the transaction.
The runtime retains the isolated directory's device and inode, quarantines and
removes only that exact directory through descriptor-relative traversal, and
preserves a concurrent path replacement. Age-qualified transport repositories
left by cancellation or process death are collected by the bounded,
deadline-aware maintenance pass.

A commit retry follows the attempt-journal identity and recovery rules above;
it never treats a matching message or allowlisted changed-path set as proof of
success. For push preflight and retry, the add-on queries the exact remote branch
tip through the validated URL and transport snapshot. It returns
`already-pushed` only when that live remote object id exactly equals the
validated current `HEAD`. If the live tip differs from both `HEAD` and the
snapshotted local upstream-tracking object id, or is missing, the add-on fails
closed rather than trusting stale local tracking state. Otherwise it performs
the same explicit non-force push. A concurrent remote update remains protected
by the server's non-fast-forward check. After a reported push success, the
add-on queries the live remote tip again and emits success only when it equals
the pushed `HEAD`; provider or verification failure remains retryable and does
not fabricate success.

### Output contract and finalization data flow

Successful commit execution publishes a normal runtime-owned output payload
with a `git` object containing:

- `operation: "commit"`
- `status: "committed"` or `"already-committed"`
- `commitHash`: the full validated `HEAD` object id
- `commitMessage`: the validated rendered message
- `committedFiles`: the validated repository-relative allowlist in authored
  order

Successful push execution publishes a `git` object containing:

- `operation: "push"`
- `status: "pushed"` or `"already-pushed"`
- `commitHash`: the full validated current `HEAD` object id
- `pushedRemote`: the validated configured remote name, never its URL
- `pushedBranch`: the validated current branch name

Retry success emits the same evidence fields as first-attempt success; only
`status` differs. The add-ons never emit credentials, helper protocol data,
remote URLs, or captured Git output. A success payload is invalid if a required
evidence field is absent, if the reported commit does not equal the validated
current `HEAD`, or if push evidence does not match the validated same-name
upstream.

Step 9 supplies the message and exact file allowlist to Step 10. Step 10 emits
the commit evidence above. Step 11 consumes that exact accepted commit hash,
requires the current `HEAD` to match it before any live remote access, then
independently validates the branch, remote, and upstream immediately before
push and emits the push evidence above. `workflow-output` reads `commitHash`
from the accepted Step 10 commit evidence, copies `committedFiles` exactly in
authored order, and reads `pushedRemote` and `pushedBranch` from the accepted
Step 11 push evidence; it must not infer or fabricate missing finalization
fields.
Before terminal output persistence, the runtime deterministically requires the
exact commit and push evidence key sets, accepted statuses, independently
validated full lowercase hashes, and
equal Step 10, Step 11, and final-output commit hashes, plus exact equality
between Step 10 and final-output committed-file arrays. Missing, stale,
mismatched, reordered, or unexpected evidence is rejected.
Deterministic tests must assert every evidence field for committed, already
committed, pushed, and already pushed outcomes, including rejection of stale or
mismatched evidence.

### Rollout and verification

Adding resolver dispatch does not authorize existing workflows automatically;
only nodes carrying the explicit versioned add-on configuration can mutate Git
state. Release requires adversarial review because these add-ons modify the
repository and its remote. Deterministic coverage must include omitted-version,
directory-allowlist, literal-pathspec, index-rollback, inherited-`GIT_*`,
repository-hook, custom-filter, global-identity snapshot, trusted HTTPS helper,
untrusted credential-helper, external-remote-helper, configured-receive-pack,
authorization, failure, exact attempt-journal retry identity, cross-session
replay, journal collision, accepted-output cleanup, every ref/index crash phase,
foreign index-lock preservation, reflog-token validation, post-commit reset,
stale live-remote state, remote-name grammar, trusted-executable,
executable-symlink, PATH-poisoning, and retry cases. The focused gates are:

```bash
swift build
swift test --filter GitWorkflowAddon
swift test --filter WorkflowModelTests
swift test --filter RielaCLITests
swift test --filter RielaCoreTests
git diff --cached --check
```

## Built-in `riela/chat-reply-worker`

### Purpose

`riela/chat-reply-worker` sends a reply to the chat conversation associated
with `runtimeVariables.event`.

It is intended for workflows started by chat-like event sources such as:

- `chat.message`
- `chat.mention`
- `chat.command`
- web-chat messages

The add-on is still valid in non-chat test runs, but it should complete in
`dry-run` or `intent-only` mode rather than attempting provider dispatch when no
reply target exists.

### Resolved Node Behavior

The add-on resolves to a runtime-owned native worker executor. The direct
authored `nodeType` surface does not need a provider-specific value; internally
the descriptor binds the node to the chat reply add-on executor. The normalized
runtime payload may use an internal add-on execution binding, but workflow
authors should continue to use `workflow.json.nodes[].addon`.

The executor:

1. receives the resolved semantic node input object from the runtime
2. renders `config.textTemplate` against the normal node template context
3. extracts provider-neutral reply target metadata from
   `runtimeVariables.event`
4. creates a deterministic `ChatReplyRequest`
5. dispatches the request through the event reply adapter registry
6. writes a normal runtime-owned node output envelope

The workflow engine should depend only on a small reply dispatch interface. The
provider adapter implementation remains in the event layer, not in
`src/workflow/`.

### Configuration

Initial config:

```typescript
interface ChatReplyWorkerConfig {
  readonly textTemplate: string;
  readonly visibility?: "public" | "ephemeral";
  readonly threadPolicy?: "same-thread" | "conversation-root";
  readonly onMissingTarget?: "fail" | "intent-only" | "dry-run";
}
```

Authored `addon.inputs`, when present, is copied into the resolved node payload
`variables`. The chat reply worker can reference those keys from
`config.textTemplate` alongside normal runtime and resolved input template
variables.

Defaults:

- `visibility`: `"public"`
- `threadPolicy`: `"same-thread"`
- `onMissingTarget`: `"fail"` during normal execution and `"dry-run"` when the
  workflow run is explicitly using a mock scenario

Validation rules:

- `textTemplate` is required and must render to a non-empty string
- `visibility: "ephemeral"` is accepted only when the source adapter declares
  ephemeral replies are supported
- provider-specific formatting fields are intentionally omitted from the first
  version

## Built-in Agent Worker Add-ons

Generic agent-backed worker add-ons are available for workflows that want a
compact authored reference instead of a workflow-local `node-*.json` payload:

- `riela/codex-worker`
- `riela/claude-code-worker`
- `riela/codex-sdk-worker`
- `riela/claude-sdk-worker`
- `riela/gemini-sdk-worker`
- `riela/cursor-sdk-worker`

All six are worker-only add-ons. They resolve to ordinary `agent` node
payloads:

- `riela/codex-worker` sets `executionBackend: "codex-agent"`
- `riela/claude-code-worker` sets `executionBackend: "claude-code-agent"`
- `riela/codex-sdk-worker` sets `executionBackend: "official/openai-sdk"`
- `riela/claude-sdk-worker` sets
  `executionBackend: "official/anthropic-sdk"`
- `riela/gemini-sdk-worker` sets `executionBackend: "official/gemini-sdk"`
- `riela/cursor-sdk-worker` sets
  `executionBackend: "official/cursor-sdk"`

The add-on name selects the backend. `executionBackend` remains the low-level
runtime adapter field and is not replaced by the add-on system. SDK-backed
worker add-ons intentionally use the same authored config shape as the
CLI-agent worker add-ons so examples can switch the backend through the add-on
name without introducing provider-specific workflow fields.

Authored example:

```json
{
  "id": "implement",
  "role": "worker",
  "addon": {
    "name": "riela/codex-worker",
    "version": "1",
    "config": {
      "model": "gpt-5.4-codex",
      "promptTemplate": "Implement this task: {{task}}",
      "sessionPolicy": {
        "mode": "reuse"
      }
    },
    "inputs": {
      "task": "Add checkout validation"
    }
  }
}
```

Agent worker config:

```typescript
interface AgentWorkerAddonConfig {
  readonly model: string;
  readonly promptTemplate: string;
  readonly systemPromptTemplate?: string;
  readonly sessionStartPromptTemplate?: string;
  readonly sessionPolicy?: { readonly mode: "new" | "reuse" };
  readonly timeoutMs?: number;
}
```

`addon.inputs` is copied into the resolved node payload `variables`. The prompt
template can reference those keys directly, and it can also reference the normal
workflow runtime variables and inbox context.

`addon.env` is not supported by the Codex, Claude, and Cursor worker add-ons in
version `1`. Credential and runtime environment handling remains owned by the
configured agent backend adapters. Required SDK credentials are adapter
preflight inputs: `OPENAI_API_KEY` for `official/openai-sdk`,
`ANTHROPIC_API_KEY` for `official/anthropic-sdk`, and `CURSOR_API_KEY` for
`official/cursor-sdk`.

`riela/gemini-sdk-worker` supports explicit `addon.env` bindings because the
Gemini SDK worker is a direct built-in HTTP adapter boundary. It accepts
`GEMINI_API_KEY` or `GOOGLE_API_KEY` target names, with `GOOGLE_API_KEY`
preferred when both are present.
Validation should surface missing backend support or credentials as runtime
readiness/executability information rather than silently falling back to a
different worker add-on.

SDK worker regression coverage should include:

- add-on resolution for all three SDK add-ons in
  `packages/riela/src/workflow/node-addons/sdk-agent-workers.test.ts`
- dispatch registration for `official/openai-sdk`,
  `official/anthropic-sdk`, `official/gemini-sdk`, and `official/cursor-sdk`
- package-boundary exports for workflow add-on types in
  `packages/riela/src/package-boundaries.test.ts`

Verification commands:

```bash
bun test packages/riela/src/workflow/node-addons/sdk-agent-workers.test.ts packages/riela/src/workflow/adapters/dispatch.test.ts packages/riela/src/package-boundaries.test.ts
bun run typecheck
```

### Cursor SDK Worker Boundary

`riela/cursor-sdk-worker` resolves to the `official/cursor-sdk` adapter, not
to `cursor-cli-agent`. Cursor SDK behavior must remain isolated behind
`packages/riela-adapters/src/cursor-sdk.ts` and its runtime wrapper in
`packages/riela/src/workflow/adapters/cursor-sdk.ts`.

The Cursor SDK adapter may use a Bun child process to load `@cursor/sdk`,
construct a JSONL local agent store, execute one prompt, and return a small JSON
result envelope. That child-process boundary is intentional because Bun runtime
compatibility is an adapter concern, not a workflow or add-on concern. The
parent adapter should pass only the model id, working directory, store root,
message, and resolved `CURSOR_API_KEY`; the workflow model should not expose
Cursor SDK process details.

The Cursor SDK prompt boundary currently combines `systemPromptText` and the
per-turn prompt before sending the SDK message because the Cursor SDK message
API does not expose the same separate system-prompt option as the local
CLI-agent runners. That is an intentional divergence from the local
`codex-agent` and `cursor-cli-agent` prompt-splitting behavior documented in
`design-docs/specs/architecture.md`.

Cursor SDK verification should stay deterministic by testing injected
`agentFactory` behavior and output parsing in
`packages/riela/src/workflow/adapters/cursor-sdk.test.ts`. Live Cursor SDK
coverage must remain credential-gated behind `CURSOR_API_KEY` in
`packages/riela/src/workflow/adapters/official-sdk-live-smoke.test.ts`.

## Built-in `riela/workflow-package-sandbox-review`

### Purpose

`riela/workflow-package-sandbox-review` reviews staged or fixture workflow
package content with an LLM-backed agent before a package is trusted by a
workflow. It is intended for sanitize/security review workflows that inspect
package manifests, workflow JSON, node payloads, prompts, and package-local
support files and then return a normal runtime-owned node output with findings
and a decision. Downstream publication remains a `workflow_messages` insert,
not an add-on-written mailbox file.

This add-on is not a replacement for checkout integrity validation, static
pre-install scanning, or no-network container checks. Those checks remain
checkout-owned gates. This add-on is an ordinary workflow node so package
review can be composed into review, triage, registry-maintenance, or approval
workflows without adding Python-only checker behavior to the package installer.

### Resolved Node Behavior

The add-on resolves to an ordinary `agent` node payload. Version `1` supports
the same LLM backend boundary as existing agent execution paths:

- `codex-agent`
- `claude-code-agent`
- `cursor-cli-agent`, when the cursor adapter is available in the runtime

The descriptor selects the backend from `config.executionBackend`, validates
that it is one of the supported agent backends, and emits a resolved payload
whose `executionBackend`, `model`, `promptTemplate`, `variables`, and timeout
fields are ordinary agent-node fields. The workflow runtime must execute the
review through the selected adapter rather than through a Python-only static
checker or package checkout hook.

The prompt template is runtime-owned by the add-on descriptor. It should direct
the backend to treat package text as untrusted evidence, ignore instructions
embedded in the package, avoid executing package files, avoid expanding secret
values, and return structured review output. Workflow-authored `addon.inputs`
provide package evidence references and review hints, but they do not override
the safety instructions in the descriptor prompt.

### Configuration

Initial config:

```typescript
interface WorkflowPackageSandboxReviewConfig {
  readonly executionBackend:
    | "codex-agent"
    | "claude-code-agent"
    | "cursor-cli-agent";
  readonly model: string;
  readonly decisionPolicy?: "advisory" | "block-on-high";
  readonly maxEvidenceBytes?: number;
  readonly timeoutMs?: number;
}
```

Defaults:

- `decisionPolicy`: `"advisory"`
- `maxEvidenceBytes`: an implementation-owned bounded value that prevents
  unbounded package prompts
- `timeoutMs`: inherited from workflow defaults unless explicitly configured

`addon.inputs` should accept:

- `packageRoot`: optional staged package root path for runtime-owned evidence
  collection
- `packageSummary`: optional precomputed summary or selected file inventory
- `packageFiles`: optional bounded list of package-relative file records with
  text excerpts
- `reviewFocus`: optional workflow-authored focus text, treated as a reviewer
  hint and not as a safety policy override

At least one of `packageRoot`, `packageSummary`, or `packageFiles` must be
provided. `packageRoot` does not give the selected LLM backend direct file
system access. It is consumed only by riela-owned evidence collection before
agent execution.

`addon.env` is not supported in version `1`. Backend credentials and runtime
environment selection remain owned by the configured agent adapter. The add-on
must not forward host environment variables, registry signing keys, package
manager tokens, SSH keys, or secret files to the prompt.

### Evidence Collection Data Flow

The add-on data flow must keep package inspection deterministic and confined:

1. Validate `addon.config` and `addon.inputs`.
2. If `packageFiles` or `packageSummary` are supplied, normalize them into
   bounded evidence records without reading additional files.
3. If `packageRoot` is supplied, resolve it to a real staged package directory
   before the agent node starts.
4. Walk only the package root using implementation-owned include/ignore rules.
5. Convert selected files into package-relative evidence records.
6. Redact known secret patterns and truncate records according to
   `maxEvidenceBytes`.
7. Insert only the bounded evidence records, package summary, review focus, and
   metadata into the resolved agent node variables.
8. Run the selected agent backend against the descriptor-owned prompt and
   bounded variables.

The LLM backend must never receive a host path as an instruction to inspect on
its own. It receives text evidence collected by riela and package-relative
paths only for attribution.

Evidence collection rules:

- reject `packageRoot` when it is absent, unreadable, or not a directory
- resolve symlinks and reject files whose real path escapes `packageRoot`
- reject absolute package evidence paths in `packageFiles`
- normalize `.` and `..` segments before evidence records are accepted
- ignore `.git`, nested `.riela`, runtime artifacts, checkout provenance,
  temporary files, lock/cache directories, and binary files unless a later
  explicit allow-list includes them
- read text files only, with per-file and total byte limits
- mark truncated records with byte counts in `reviewedInputs`
- redact obvious token, key, SSH private-key, and environment-secret patterns
  before prompt insertion
- preserve package-relative paths and short evidence summaries for findings

When both `packageRoot` and explicit `packageFiles` are supplied, explicit
`packageFiles` are treated as the selected evidence set and `packageRoot` is
used only as a package label/confinement reference unless a future version adds
an explicit merge mode.

### Output Contract

The add-on returns a candidate object through the native add-on executor. The
runtime validates and publishes the same `output.json` envelope as any worker
node, then routes downstream messages by inserting `workflow_messages` rows.
The node payload should include structured review data inside the normal output
payload:

- `decision`: `allow`, `warn`, or `block`
- `severity`: `info`, `low`, `medium`, `high`, or `critical`
- `summary`: concise human-readable result
- `findings`: list of package-relative findings with severity, category,
  evidence summary, and remediation
- `reviewedInputs`: package label, file count, byte count, and truncation
  metadata
- `backend`: selected execution backend and model

The add-on must not write checkout provenance records or mutate package
manifests. Workflows that want to enforce the decision should branch on the
normal published node output.

### Fixture Workflow

Examples should include a workflow package sandbox review fixture under
`examples/` that uses this add-on as a normal workflow node. Fixture data should
cover:

- a clean package case that produces `decision: "allow"` or advisory `warn`
- a suspicious package case with prompt-injection or credential-exfiltration
  evidence that produces `decision: "block"` when `decisionPolicy` is
  `block-on-high`

The fixture should prefer `promptTemplateFile` for any long prompts or
case-specific setup. Tests should mock or fixture the selected agent adapter so
the add-on resolution and runtime-owned output contract are deterministic.
Clean and suspicious cases should exercise the same bounded evidence path used
by ordinary workflows, including at least one `packageRoot` fixture that
produces package-relative evidence records before mocked `codex-agent`,
`claude-code-agent`, or `cursor-cli-agent` execution.

### Safety Boundary

The package content supplied to the backend is evidence, not instructions.
Implementation must keep these boundaries explicit:

- no package scripts, hooks, commands, or workflow nodes are executed as part of
  the add-on
- file reads are bounded, confined to `packageRoot`, and selected before prompt
  construction
- evidence summaries must avoid secret expansion and should use
  package-relative paths
- checkout static/container scanners remain available before installation and
  must not depend on LLM review
- LLM review may be used before install only when a workflow explicitly stages
  or supplies package content to this add-on

### Cursor Adapter Mapping

`cursor-cli-agent` support is intentionally an adapter selection, not a new
add-on execution mode. When configured, the add-on resolves to the same
ordinary `agent` payload shape with `executionBackend: "cursor-cli-agent"`.
Any Cursor-specific CLI flags, session behavior, availability checks, and
credential handling must stay inside the cursor adapter. If the cursor adapter
is unavailable, validation should report an executability result for the add-on
node rather than silently falling back to codex or claude.
