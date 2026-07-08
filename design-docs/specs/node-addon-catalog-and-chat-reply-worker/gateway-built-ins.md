# Node Add-on Catalog and Built-in Workers: Gateway Built-ins

## Shared Container Runner Rules

All gateway add-ons use the same container runner contract:

- `runnerKind` accepts only `podman`, `docker`, `nerdctl`, or `container`
- `container` selects the Apple `container` CLI by name
- legacy aliases such as `apple` and `apple-container` are not accepted
- `runnerPath`, when provided, is an explicit executable override and takes
  precedence over `runnerKind`
- after template rendering, `runnerPath` or `runnerKind` must resolve to a
  non-empty executable name; empty or whitespace-only values fail before the
  process is launched
- when both fields are omitted, execution defaults to `docker`

## Shared Local CLI Gateway Rules

Gateway add-ons that bridge to a locally installed CLI use a narrower process
contract than container-backed add-ons:

- the runtime invokes a fixed subcommand and fixed argument shape; workflow
  authors cannot provide an arbitrary command line
- `binaryPath`, when provided in `addon.config`, is an explicit executable
  override and takes precedence over environment and `PATH` lookup; it is read
  as a literal `addon.config` value and is not rendered from workflow input,
  upstream payloads, or `addon.inputs`
- the add-on may define one environment fallback for the executable path; if it
  is unset or empty, the runtime resolves the default executable name through
  `PATH`
- no shell interpolation is used; each process argument is passed as a separate
  argument to the subprocess runner
- the child process receives only a minimal environment allowlist needed for
  local process lookup and macOS automation context, not the full ambient
  runtime environment
- stdout must be valid JSON in the upstream gateway GraphQL envelope
- stderr and process status are captured as diagnostics, but successful node
  output is derived from parsed stdout rather than stderr text

## Apple Gateway Review Hardening Boundaries

The Apple Gateway built-ins are reviewed as one cohesive local-CLI surface:
shared support, Notes, Mail, Reminders, Calendar read/write, Clock alarms,
Notifications, Admin commands, tests, and `examples/apple-*`. A hardening pass
must preserve the existing public add-on ids, versions, workflow input/output
shapes, and domain separation unless a confirmed defect cannot be fixed without
a documented contract change.

The review boundary is behavior-first:

- subprocess execution must continue to use fixed subcommands with separate
  argv elements and no shell interpolation
- executable selection must remain literal config, then the documented
  environment fallback, then `PATH`; workflow inputs and upstream payloads must
  not choose the binary
- file materialization must keep Riela-owned destination roots and sanitized
  leaf names; gateway-provided filenames are metadata only
- GraphQL query and mutation operations must keep fixed documents or validated
  variables rather than accepting arbitrary command fragments
- process output parsing must reject malformed JSON, missing required data, and
  ambiguous download mappings instead of inventing partial success
- non-zero exits, GraphQL errors, permission failures, missing helper bridges,
  unsupported host capabilities, and timeouts must map to the existing error
  classes consistently across Apple domains
- tests must use fake `apple-gateway` executables and deterministic fixtures,
  not live Apple app access, TCC state, or a locally installed gateway

Rollout is limited to in-scope Apple Gateway files and examples. Findings whose
correct fix requires changing shared adapter behavior outside the Apple Gateway
source files must be recorded as follow-up TODOs rather than folded into this
pass.

## Built-in `riela/apple-notes-list`

### Purpose

`riela/apple-notes-list` runs a read-only Apple Notes GraphQL query through a
locally installed `apple-gateway` CLI. It is intended for workflow nodes that
need to inspect Apple Notes without vendoring `apple-gateway` source or giving
workflow authors arbitrary process execution.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. Version `1` always invokes:

```bash
apple-gateway graphql --query <rendered-query>
```

The confirmed upstream envelope is a GraphQL JSON object such as:

```json
{
  "data": {
    "permissions": {
      "notesAutomation": "NOT_DETERMINED"
    }
  },
  "extensions": {
    "requestId": "4024CD0C-FF60-4FF5-9150-B53C5AF1EBDF"
  }
}
```

### Authored Example

```json
{
  "id": "list-apple-notes",
  "role": "worker",
  "addon": {
    "name": "riela/apple-notes-list",
    "version": "1",
    "config": {
      "first": 25,
      "includePlaintext": false,
      "includeBodyHtml": false,
      "includeBodyFiles": false,
      "includeAttachments": false
    },
    "inputs": {
      "accountId": "{{workflowInput.accountId}}",
      "folderId": "{{workflowInput.folderId}}",
      "query": "{{workflowInput.query}}"
    }
  }
}
```

### Configuration

```typescript
interface AppleNotesListAddonConfig {
  readonly binaryPath?: string;
  readonly first?: number;
  readonly accountId?: string;
  readonly folderId?: string;
  readonly query?: string;
  readonly modifiedAfter?: string;
  readonly modifiedBefore?: string;
  readonly after?: string;
  readonly includePlaintext?: boolean;
  readonly includeBodyHtml?: boolean;
  readonly includeBodyFiles?: boolean;
  readonly includeAttachments?: boolean;
}
```

Defaults:

- `binaryPath`: `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through
  `PATH`
- `first`: `25`
- include flags: `false`

Execution behavior:

1. render supported filter values and `addon.inputs` with the normal node
   template context
2. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`; `binaryPath` is never sourced from
   workflow input, upstream payloads, or `addon.inputs`
3. run `apple-gateway graphql --query <rendered-query>` with separate process
   arguments, no shell interpolation, and a minimal child environment allowlist
4. parse JSON stdout into `appleNotes.accounts`, `appleNotes.folders`,
   `appleNotes.notes`, `appleNotes.pageInfo`, `appleNotes.totalCount`, and
   `appleNotes.requestId`
5. expose bounded process provenance under `appleGateway.binary`

Validation and error rules:

- version `1` only
- `addon.env` is rejected; the executable fallback reads `APPLE_GATEWAY_BIN`
  from the runtime environment directly
- ambient runtime environment values such as provider API keys, GitHub tokens,
  and Riela secrets are not forwarded to the `apple-gateway` subprocess
- `first` must be between `1` and `100`
- include flags must be booleans
- missing or non-executable binary maps to policy blocked
- non-zero process exit and GraphQL `errors` map to provider error
- malformed JSON or missing GraphQL `data` maps to invalid output

## Built-in `riela/apple-notifications-list`

### Purpose

`riela/apple-notifications-list` runs a read-only Apple Notifications GraphQL
query through a locally installed `apple-gateway` CLI. It is intended for
workflow nodes that need to inspect delivered notifications without vendoring
`apple-gateway` source or giving workflow authors arbitrary process execution.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. Version `1` always invokes:

```bash
apple-gateway graphql --query <rendered-query>
```

Only this notifications add-on is read-only. The post and dismiss add-ons below
are mutation-capable and must be reviewed as side-effecting operations.

### Authored Example

```json
{
  "id": "list-apple-notifications",
  "role": "worker",
  "addon": {
    "name": "riela/apple-notifications-list",
    "version": "1",
    "config": {
      "source": "GATEWAY_HELPER",
      "first": 25
    },
    "inputs": {
      "appBundleId": "{{workflowInput.appBundleId}}",
      "deliveredAfter": "{{workflowInput.deliveredAfter}}"
    }
  }
}
```

### Configuration

```typescript
interface AppleNotificationsListAddonConfig {
  readonly binaryPath?: string;
  readonly source?: "GATEWAY_HELPER" | "SYSTEM_DB";
  readonly appBundleId?: string;
  readonly deliveredAfter?: string;
  readonly deliveredBefore?: string;
  readonly first?: number;
  readonly after?: string;
}
```

Defaults:

- `binaryPath`: `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through
  `PATH`
- `first`: `25`

Execution behavior:

1. render supported filter values and `addon.inputs` with the normal node
   template context
2. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`; `binaryPath` is never sourced from
   workflow input, upstream payloads, or `addon.inputs`
3. validate `source` as an enum and inline it as an unquoted GraphQL enum value
4. run `apple-gateway graphql --query <rendered-query>` with separate process
   arguments, no shell interpolation, and a minimal child environment allowlist
5. parse JSON stdout into `appleNotifications.notifications`,
   `appleNotifications.pageInfo`, `appleNotifications.totalCount`, and
   `appleNotifications.requestId`
6. expose `notificationCount`, `replyText`, and bounded process provenance
   under `appleGateway.binary`

The fixed selection includes `id`, `source`, `appBundleId`, `title`,
`subtitle`, `body`, and `deliveredAt`. Edge cursors are merged onto returned
notification nodes for downstream paging.

Validation and error rules:

- version `1` only
- `addon.env` is rejected; the executable fallback reads `APPLE_GATEWAY_BIN`
  from the runtime environment directly
- ambient runtime environment values such as provider API keys, GitHub tokens,
  and Riela secrets are not forwarded to the `apple-gateway` subprocess
- `source` must be `GATEWAY_HELPER` or `SYSTEM_DB`
- `first` must be between `1` and `100`
- missing or non-executable binary maps to policy blocked
- non-zero process exit and GraphQL `errors` map to provider error
- malformed JSON, missing GraphQL `data`, or missing notification connection
  data maps to invalid output
- deadline expiry terminates the subprocess and maps to timeout

## Built-in `riela/apple-notification-post`

### Purpose

`riela/apple-notification-post` posts one notification through the
AppleGatewayNotifier.app helper via `apple-gateway`. It supports notification
actions, optional reply capture, bounded wait time, and gateway fallback
behavior. It is intentionally separate from the read-only list add-on so a
workflow node that can inspect notifications cannot become a mutation by
changing input data.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. Version `1` always invokes:

```bash
apple-gateway graphql --query <rendered-mutation>
```

### Authored Example

```json
{
  "id": "post-demo-notification",
  "role": "worker",
  "addon": {
    "name": "riela/apple-notification-post",
    "version": "1",
    "config": {
      "title": "Riela demo notification",
      "body": "This notification will be dismissed by the next workflow node.",
      "allowFallback": true,
      "waitSeconds": 0
    }
  }
}
```

### Configuration

```typescript
interface AppleNotificationPostAddonConfig {
  readonly binaryPath?: string;
  readonly title?: string;
  readonly subtitle?: string;
  readonly body?: string;
  readonly sound?: boolean;
  readonly actions?: string[];
  readonly allowReply?: boolean;
  readonly waitSeconds?: number;
  readonly allowFallback?: boolean;
}
```

Defaults:

- `binaryPath`: `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through
  `PATH`
- `sound`, `allowReply`, and `allowFallback`: omitted unless configured
- `waitSeconds`: omitted unless configured; configured values must be `0...300`

Execution behavior:

1. reject unsupported versions and any authored `addon.env`
2. render `title`, `subtitle`, `body`, and each `actions` value from config and
   `addon.inputs`
3. require `title` to resolve to a non-empty string
4. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`
5. build a fixed `postNotification(input:)` mutation with values encoded as
   GraphQL literals using the shared `appleGatewayGraphQLString` helper
6. run `apple-gateway graphql --query <rendered-mutation>` with separate
   process arguments and no shell interpolation
7. parse `data.postNotification` into `appleNotification.posted` with `id`,
   `delivered`, `usedFallback`, and optional `activation { kind actionLabel
   replyText }`
8. expose top-level `postedNotificationId` for a downstream dismiss node and
   `when.always`, `when.delivered`, and `when.used_fallback`

Validation and error rules:

- version `1` only
- `addon.env` is rejected
- `title` is required after rendering
- `actions`, when present, must be a string array after rendering
- `waitSeconds` must be between `0` and `300`
- missing or non-executable binary maps to policy blocked
- non-zero process exit and GraphQL `errors` map to provider error
- malformed JSON, missing GraphQL `data`, or missing
  `data.postNotification` maps to invalid output
- deadline expiry terminates the subprocess and maps to timeout; this matters
  when `waitSeconds` asks the helper to wait for an action or reply

## Built-in `riela/apple-notifications-dismiss`

### Purpose

`riela/apple-notifications-dismiss` dismisses notifications through
`apple-gateway`. It supports exactly two explicit modes: dismiss the supplied
notification ids, or dismiss all gateway notifications. Workflows must select
one mode only. The shipped example must dismiss only the id returned by its own
`riela/apple-notification-post` node and must never use dismiss-all.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. Version `1` always invokes:

```bash
apple-gateway graphql --query <rendered-mutation>
```

### Authored Example

```json
{
  "id": "dismiss-posted-notification",
  "role": "worker",
  "addon": {
    "name": "riela/apple-notifications-dismiss",
    "version": "1",
    "inputs": {
      "ids": ["{{_rielaInput.latest.payload.postedNotificationId}}"]
    }
  }
}
```

### Configuration

```typescript
interface AppleNotificationsDismissAddonConfig {
  readonly binaryPath?: string;
  readonly ids?: string[];
  readonly all?: boolean;
}
```

Defaults:

- `binaryPath`: `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through
  `PATH`
- no default dismiss mode; `ids` or `all: true` must be authored

Execution behavior:

1. reject unsupported versions and any authored `addon.env`
2. render configured and input `ids` values with the normal node template
   context
3. require exactly one resolved mode: a non-empty `ids` array or `all: true`
4. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`
5. build either `dismissNotifications(ids:)` or
   `dismissAllGatewayNotifications` as a fixed mutation with values encoded as
   GraphQL literals
6. run `apple-gateway graphql --query <rendered-mutation>` with separate
   process arguments and no shell interpolation
7. parse the mutation result into `appleNotifications.dismissedCount`,
   `appleNotifications.mode`, and `appleNotifications.requestId`
8. expose top-level `dismissedCount` and `replyText`

Validation and error rules:

- version `1` only
- `addon.env` is rejected
- neither mode, both modes, or an empty `ids` array maps to policy blocked
- missing or non-executable binary maps to policy blocked
- non-zero process exit and GraphQL `errors` map to provider error
- malformed JSON, missing GraphQL `data`, or missing mutation result object maps
  to invalid output
- deadline expiry terminates the subprocess and maps to timeout

### Apple Notifications Helper and Permissions

Notifications add-ons reuse the same shared local CLI gateway rules as
`riela/apple-notes-list`: process invocation is centralized in the
apple-gateway bridge, arguments are passed without shell interpolation, and the
binary is resolved from literal `addon.config.binaryPath`,
`APPLE_GATEWAY_BIN`, then `PATH`.

`riela/apple-notification-post` depends on AppleGatewayNotifier.app. The first
post on a macOS host may trigger the helper's notification authorization prompt.
Operational setup should be checked with:

```bash
apple-gateway permissions status --json
```

The relevant permission states are `notificationsHelper` for helper
availability/authorization and `notificationDbFullDiskAccess` for
`SYSTEM_DB` reads. Helper failures and Full Disk Access failures remain
provider errors so workflow policy does not change based on advisory text.
When upstream error text mentions `notifier`, `AppleGatewayNotifier`, or
`helper`, the adapter should append guidance to install and authorize
AppleGatewayNotifier.app and run the permissions status command. When upstream
error text mentions `full disk access` or `notification DB`, the adapter should
append guidance to grant Full Disk Access to the apple-gateway host for
`SYSTEM_DB` notification reads.

Tests must use fake `apple-gateway` executables only. Required coverage includes
query, post, dismiss-by-id, dismiss-all, action/reply/wait input construction,
binary precedence, minimal child environment forwarding, rejected `addon.env`,
unsupported versions, malformed or missing data, non-zero exits, helper
unavailable guidance, Full Disk Access guidance, and timeout behavior.

## Built-in `riela/apple-note-*`

### Purpose

The Apple Notes CRUD add-ons extend the read-only list integration with
fixed-operation Notes add-ons:

- `riela/apple-note-get`: read one note by `noteId`
- `riela/apple-note-create`: create a note
- `riela/apple-note-update-body`: replace or append to a note body
- `riela/apple-note-delete`: delete a note
- `riela/apple-note-move`: move a note to another folder

Each operation has its own add-on id and version `1`. Reads and mutations are
intentionally split so a workflow node granted `riela/apple-note-get` cannot be
changed into a destructive operation through config or input data. All five
add-ons use the shared local CLI gateway rules, reuse the same apple-gateway
binary resolver as `riela/apple-notes-list`, and do not vendor
`apple-gateway`.

Version `1` always invokes GraphQL with a fixed document and typed variables:

```bash
apple-gateway graphql --query <fixed-document> --variables <json>
```

User text, note ids, folder ids, and mutation inputs travel only in the
`--variables` JSON argument. The GraphQL document is never built by
interpolating user-controlled values.

### Authored Examples

Read one note:

```json
{
  "id": "get-apple-note",
  "role": "worker",
  "addon": {
    "name": "riela/apple-note-get",
    "version": "1",
    "config": {
      "includePlaintext": true,
      "materializeBody": false
    },
    "inputs": {
      "noteId": "{{workflowInput.noteId}}"
    }
  }
}
```

Create one note:

```json
{
  "id": "create-apple-note",
  "role": "worker",
  "addon": {
    "name": "riela/apple-note-create",
    "version": "1",
    "inputs": {
      "title": "{{workflowInput.title}}",
      "bodyText": "{{workflowInput.bodyText}}",
      "folderId": "{{workflowInput.folderId}}"
    }
  }
}
```

Mutation add-ons other than create are documented as snippets only and should
not be shipped as runnable default examples:

```json
{ "name": "riela/apple-note-update-body", "version": "1" }
{ "name": "riela/apple-note-delete", "version": "1" }
{ "name": "riela/apple-note-move", "version": "1" }
```

### Configuration and Inputs

```typescript
interface AppleNoteGetAddonConfig {
  readonly binaryPath?: string;
  readonly includePlaintext?: boolean;
  readonly includeBodyHtml?: boolean;
  readonly includeBodyFile?: boolean;
  readonly includeAttachments?: boolean;
  readonly materializeBody?: boolean;
  readonly downloadDir?: string;
}

interface AppleNoteCreateAddonConfig {
  readonly binaryPath?: string;
}

interface AppleNoteUpdateBodyAddonConfig {
  readonly binaryPath?: string;
  readonly mode?: "REPLACE" | "APPEND";
}

interface AppleNoteDeleteAddonConfig {
  readonly binaryPath?: string;
}

interface AppleNoteMoveAddonConfig {
  readonly binaryPath?: string;
}
```

Inputs:

- `riela/apple-note-get`: `noteId`
- `riela/apple-note-create`: optional `accountId`, optional `folderId`,
  required `title`, and at least one of `bodyHtml` or `bodyText`
- `riela/apple-note-update-body`: `noteId`, optional `mode`, and at least one
  of `bodyHtml` or `bodyText`; input `mode` overrides config `mode` when
  provided
- `riela/apple-note-delete`: `noteId`
- `riela/apple-note-move`: `noteId`, `folderId`

Defaults:

- `binaryPath`: `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through
  `PATH`
- `includePlaintext`: `true`
- `includeBodyHtml`: `false`
- `includeBodyFile`: `false`
- `includeAttachments`: `false`
- `materializeBody`: `false`
- update mode: `REPLACE`
- `downloadDir`: unset; materialization must use a valid private runtime
  directory from config or `RIELA_APPLE_NOTES_DOWNLOAD_ROOT`

### Execution Behavior

All five add-ons:

1. reject unsupported versions and any authored `addon.env`
2. render supported config and input fields with the normal node template
   context
3. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`
4. run `apple-gateway graphql --query <fixed-document> --variables <json>` with
   separate process arguments and no shell interpolation
5. parse JSON stdout as a GraphQL envelope, preserving `extensions.requestId`
6. publish `status`, `addon`, `stepId`, `appleGateway.binary`,
   `appleGateway.requestId`, and `appleGateway.rawData`

Operation-specific output:

- get: `appleNote`; `when.has_note`
- create: `appleNote`, `created: true`; `when.created`
- update-body: `appleNote`, `updated: true`; `when.updated`
- delete: `deleteResult.success`, `deleted`; `when.deleted`
- move: `appleNote`, `moved: true`; `when.moved`

#### `riela/apple-note-get`

Runs fixed query `note(noteId: $noteId)`. Selected fields include id, account,
folder, name, snippet, protection/share flags, timestamps, and optional
plaintext, HTML body, `bodyFile`, and attachments based on config flags.

If `data.note` is null or missing, the add-on succeeds with no `appleNote`
object and `when.has_note: false`. If `data.note` is present but is not an
object, the gateway output is malformed and maps to invalid output rather than
being treated as "not found".

#### `riela/apple-note-create`

Runs fixed mutation `createNote(input: $input)`. The input object contains
optional account/folder ids, required title, and body fields. The output returns
created note identity and timestamps plus `created: true`.

#### `riela/apple-note-update-body`

Runs fixed mutation `updateNoteBody(input: $input)`. Mode is `REPLACE` or
`APPEND`; body HTML or body text is required. The output returns updated note
identity, snippet, modification date, and `updated: true`.

#### `riela/apple-note-delete`

Runs fixed mutation `deleteNote(noteId: $noteId)`. The output exposes
`deleteResult.success` and derives `deleted` from that boolean.

#### `riela/apple-note-move`

Runs fixed mutation `moveNote(noteId: $noteId, folderId: $folderId)`. The output
returns moved note identity, updated folder id, modification date, and
`moved: true`.

The get add-on selects note fields from fixed include flags. When
`materializeBody` is true, the runtime also requests `bodyFile` and, when the
gateway returns `bodyFile.downloadKey`, invokes:

```bash
apple-gateway file download --key <download-key> --output-dir <root>
```

The downloader uses the same process runner and binary resolution boundary as
GraphQL. The output root must be a private runtime directory supplied by
literal `config.downloadDir` or by `RIELA_APPLE_NOTES_DOWNLOAD_ROOT`; otherwise
execution fails before launch. A successful download records the local path in
`appleNote.bodyFile.localPath` and `appleNote.body.materializedPath`. A note
without `bodyFile.downloadKey` is still a successful small-body read.

Download-root validation is side-effect-free until every existing parent
component has been checked. The runtime must resolve existing parent
components, reject symlink components, reject resolved paths outside the allowed
private runtime roots, and only then create missing descendants below the
validated root. A rejected `downloadDir` must not create the requested directory
or any outside directory reached through an intermediate symlink.

Open upstream confirmations for the exact file download stdout envelope and
locked-note / permission-denied GraphQL error shapes are tracked in
`design-docs/user-qa/qa-apple-notes-crud-gateway-confirmations.md`. Until those
are answered, implementation should parse file-download output tolerantly while
requiring an explicit download-key to local-path mapping, and provider errors
should preserve both `errors[].message` and `errors[].extensions`.

### Validation and Error Rules

- version `1` only
- `addon.env` is rejected
- missing or non-executable binary maps to policy blocked
- required input missing, empty create title, empty create/update body, invalid
  update mode, or invalid materialization root maps to policy blocked
- non-zero process exit and file-download failures map to provider error
- GraphQL `errors` map to provider error and preserve upstream messages and
  extension codes such as `NOTE_LOCKED` or permission-denied details
- malformed or non-UTF8 JSON, missing GraphQL `data`, a present non-object
  `data.note`, or a missing expected mutation field maps to invalid output
- for get, null or missing `data.note` is a successful not-found result with
  `when.has_note: false`
- deadline expiry terminates the subprocess process group, including descendant
  processes, and maps to timeout

### Security and Rollout Notes

The implementation should extract the shared `apple-gateway` support used by
`riela/apple-notes-list` into an internal support module before adding CRUD
executors. Process invocation logic must not be duplicated across list, get,
create, update, delete, and move.

Tests must use fake `apple-gateway` executables only. The required matrix covers
success paths for get/materialize/create/update replace/update append/delete/
move and failures for `NOTE_LOCKED`, permission denial, missing or non-
executable binary, non-zero exit, malformed JSON, timeout, rejected
`addon.env`, unsupported version, and variables-not-injected. The injection test
must prove user text containing quotes, braces, or newlines appears only in
`--variables`, not in `--query`.

Post-review hardening coverage is required for three edge cases: intermediate
symlink `downloadDir` rejection with no directory creation side effects,
non-object `data.note` rejection as invalid output while null or missing notes
remain `has_note: false`, and timeout cleanup that proves descendant processes
cannot survive destructive mutation add-on calls.

The read example may default to `materializeBody: false`. The create example is
allowed because it only creates a new note. Delete, move, and update should
appear only in documentation snippets unless a future example is explicitly
designed as opt-in destructive.

## Built-in `riela/apple-reminder-*`

### Purpose

The Apple Reminders add-ons expose fixed-operation Reminders GraphQL operations
through a locally installed `apple-gateway` CLI. The operation split is part of
the security contract: a workflow node authored for a read operation cannot be
changed into a mutation by changing config, inputs, or upstream payload data.

Read add-ons:

- `riela/apple-reminder-lists`: read reminder lists through `reminderLists`
- `riela/apple-reminders-list`: search reminders through
  `reminders(input: ReminderSearchInput!)`
- `riela/apple-reminder-get`: read one reminder through `reminder(reminderId:)`

Mutation add-ons:

- `riela/apple-reminder-list-create`: create a reminder list through
  `createReminderList(input:)`
- `riela/apple-reminder-create`: create a reminder through
  `createReminder(input:)`
- `riela/apple-reminder-update`: sparsely update a reminder through
  `updateReminder(input:)`
- `riela/apple-reminder-delete`: delete a reminder through
  `deleteReminder(reminderId:)`
- `riela/apple-reminder-complete`: set completion state through
  `setReminderCompleted(reminderId:, completed:)`
- `riela/apple-reminder-alarms-set`: replace reminder alarms through
  `setReminderAlarms(reminderId:, alarms:)`

Each add-on has version `1`, uses the shared local CLI gateway rules, reuses the
same `apple-gateway` binary resolver and process runner as the Apple Notes
add-ons, and does not vendor `apple-gateway`.

Version `1` always invokes GraphQL with a fixed document and typed variables:

```bash
apple-gateway graphql --query <fixed-document> --variables <json>
```

Reminder ids, list ids, search text, titles, notes, URLs, dates, priority,
completion state, and alarms travel only in the `--variables` JSON argument. The
GraphQL document is never built by interpolating workflow-controlled values.

### Authored Example

The shipped example must stay read-only. It may list reminder lists and open
reminders, but it must not use mutation add-ons:

```json
{
  "id": "list-open-reminders",
  "role": "worker",
  "addon": {
    "name": "riela/apple-reminders-list",
    "version": "1",
    "config": {
      "status": "INCOMPLETE",
      "first": 25
    },
    "inputs": {
      "listIds": "{{workflowInput.listIds}}",
      "query": "{{workflowInput.query}}"
    }
  }
}
```

Mutation add-ons are documented as explicit opt-in snippets only:

```json
{ "name": "riela/apple-reminder-list-create", "version": "1" }
{ "name": "riela/apple-reminder-create", "version": "1" }
{ "name": "riela/apple-reminder-update", "version": "1" }
{ "name": "riela/apple-reminder-delete", "version": "1" }
{ "name": "riela/apple-reminder-complete", "version": "1" }
{ "name": "riela/apple-reminder-alarms-set", "version": "1" }
```

### Configuration and Inputs

All add-ons accept optional literal `config.binaryPath`. The executable
resolution order is:

1. literal `addon.config.binaryPath`
2. `APPLE_GATEWAY_BIN` from the runtime environment
3. `apple-gateway` resolved through `PATH`

`binaryPath` is never read from `addon.inputs`, workflow input, or upstream
payloads.

```typescript
interface AppleReminderListsAddonConfig {
  readonly binaryPath?: string;
}

interface AppleRemindersListAddonConfig {
  readonly binaryPath?: string;
  readonly listIds?: readonly string[];
  readonly status?: "ALL" | "INCOMPLETE" | "COMPLETED";
  readonly dueAfter?: string;
  readonly dueBefore?: string;
  readonly query?: string;
  readonly first?: number;
  readonly after?: string;
}

interface AppleReminderGetAddonConfig {
  readonly binaryPath?: string;
  readonly reminderId?: string;
}

interface AppleReminderListCreateAddonConfig {
  readonly binaryPath?: string;
  readonly title?: string;
  readonly sourceTitle?: string;
  readonly colorHex?: string;
}

interface AppleReminderCreateAddonConfig {
  readonly binaryPath?: string;
  readonly title?: string;
  readonly listId?: string;
  readonly notes?: string;
  readonly url?: string;
  readonly priority?: number;
  readonly startDate?: string;
  readonly dueDate?: string;
  readonly dueDateHasTime?: boolean;
  readonly alarms?: readonly AppleReminderAlarmInput[];
}

interface AppleReminderUpdateAddonConfig {
  readonly binaryPath?: string;
  readonly reminderId?: string;
  readonly title?: string;
  readonly listId?: string;
  readonly notes?: string;
  readonly url?: string;
  readonly priority?: number;
  readonly startDate?: string;
  readonly dueDate?: string;
  readonly dueDateHasTime?: boolean;
  readonly alarms?: readonly AppleReminderAlarmInput[];
}

interface AppleReminderDeleteAddonConfig {
  readonly binaryPath?: string;
  readonly reminderId?: string;
}

interface AppleReminderCompleteAddonConfig {
  readonly binaryPath?: string;
  readonly reminderId?: string;
  readonly completed?: boolean;
}

interface AppleReminderAlarmsSetAddonConfig {
  readonly binaryPath?: string;
  readonly reminderId?: string;
  readonly alarms?: readonly AppleReminderAlarmInput[];
}

interface AppleReminderAlarmInput {
  readonly relativeOffsetSeconds?: number;
  readonly absoluteDate?: string;
}
```

Inputs use the same field names as config, except `binaryPath` is intentionally
ignored from inputs. Config values provide defaults; rendered `addon.inputs`
values provide per-run values for operation fields.

Operation-specific rules:

- `riela/apple-reminder-lists`: no operation inputs
- `riela/apple-reminders-list`: `listIds` defaults to `[]`; `status` defaults
  to `INCOMPLETE`; `first` defaults to `25` and must be `1...100`; `dueAfter`,
  `dueBefore`, `query`, and `after` are optional
- `riela/apple-reminder-get`: `reminderId` is required
- `riela/apple-reminder-list-create`: non-empty `title` is required;
  `sourceTitle` and `colorHex` are optional
- `riela/apple-reminder-create`: non-empty `title` is required; `priority`
  defaults to `0` and must be `0...9`; `dueDateHasTime` is omitted unless
  explicitly configured or provided as an input so `apple-gateway` applies its
  create default; `listId`, `notes`, `url`, `startDate`, `dueDate`, and `alarms`
  are optional
- `riela/apple-reminder-update`: `reminderId` is required; all update fields are
  optional and unset keys are omitted so the update is sparse
- `riela/apple-reminder-delete`: `reminderId` is required
- `riela/apple-reminder-complete`: `reminderId` is required; `completed`
  defaults to `true`
- `riela/apple-reminder-alarms-set`: `reminderId` is required; `alarms` is
  required and may be an empty array to clear alarms

Alarm entries must be objects with at least one recognized key. Recognized keys
are `relativeOffsetSeconds` as an integer and `absoluteDate` as a DateTime
string. Malformed alarm arrays fail before the subprocess is launched.

`recurrenceRules` is intentionally omitted from create and update version `1`.

### Execution Behavior

All nine add-ons:

1. reject unsupported versions and any authored `addon.env`
2. render supported config and input fields with the normal node template
   context
3. validate required fields, enums, scalar types, priorities, pagination limits,
   and alarm entries before spawning a process
4. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`
5. run `apple-gateway graphql --query <rendered-query>` with
   separate process arguments and no shell interpolation
6. parse JSON stdout as a GraphQL envelope, preserving `extensions.requestId`
7. publish the common native add-on output envelope and the
   operation-specific `appleReminders` payload

Common output envelope for all nine add-ons:

- `provider`: `"apple-gateway"`
- `model`: the authored add-on name
- `completionPassed`: `true`
- `status`, `addon`, and `stepId`
- `appleGateway.binary`, `appleGateway.requestId`, and
  `appleGateway.rawData`
- `appleReminders`: the operation-specific Reminders payload

Operation-specific output:

- reminder-lists: `appleReminders.lists`, `listCount`
- reminders-list: `appleReminders.reminders`, `pageInfo`, `totalCount`,
  `reminderCount`; `when.has_reminders`
- reminder-get: `appleReminders.reminder`, `found`; a null reminder is a
  successful not-found result
- reminder-list-create: `appleReminders.list`
- reminder-create: `appleReminders.reminder`
- reminder-update: `appleReminders.reminder`
- reminder-delete: `appleReminders.deleted.reminderId`,
  `appleReminders.deleted.success`
- reminder-complete: `appleReminders.reminder`
- reminder-alarms-set: `appleReminders.reminder`

### Validation and Error Rules

- version `1` only
- `addon.env` is rejected
- missing or non-executable binary maps to policy blocked
- required input missing, malformed arrays, invalid enum values, invalid
  priority, invalid `first`, and invalid alarm entries map to policy blocked
- non-zero process exit maps to provider error
- GraphQL `errors` map to provider error
- `deleteReminder.success == false` maps to provider error
- malformed JSON, missing GraphQL `data`, or a missing expected
  operation-specific data field maps to invalid output
- deadline expiry terminates the subprocess and maps to timeout

### Security and Rollout Notes

The implementation must extract or reuse shared `apple-gateway` support before
adding the Reminders executor. Process invocation logic must not be duplicated
between Notes and Reminders add-ons.

Tests must use fake `apple-gateway` executables only. The required matrix covers
success paths for list/search/get, list creation, create/update/delete,
completion, alarm setting, and error mapping for GraphQL errors, non-zero exit,
malformed output, missing data, missing binary, deadline expiry, binary
precedence, rejected `addon.env`, and unsupported version.

The default example under `examples/apple-reminders-list/` must be read-only and
validate offline. Workflows that use mutation add-ons should be authored as
explicit opt-in examples or user workflows, not as the default shipped example.

## Relationship Between Local Apple Mail and Container Mail Add-ons

`riela/apple-mail-list` and `riela/apple-mail-message` are local-CLI add-ons
for the signed-in macOS Mail app. They invoke a locally installed
`apple-gateway` process, require macOS Full Disk Access, reject `addon.env`, and
are read-only from Mail's perspective.

`riela/mail-gateway-read` and `riela/mail-gateway` remain container-backed
IMAP/SMTP add-ons. They use Docker-compatible runners, receive mail account
credentials through explicit `addon.env` mappings, and the non-read variant can
send mail. The two families are intentionally separate so workflows cannot turn
a local Apple Mail read node into a credentialed container mail sender by
changing config.

## Built-in `riela/apple-mail-list`

### Purpose

`riela/apple-mail-list` runs one read-only Apple Mail GraphQL query through a
locally installed `apple-gateway` CLI. It is intended for workflow nodes that
need account, mailbox, and message metadata from the local macOS Mail app
without fetching large body or attachment bytes.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. Version `1` invokes:

```bash
apple-gateway graphql --query <rendered-query>
```

The fixed document reads:

- `permissions { mailFullDiskAccess }`
- `mailAccounts { id name kind }`
- `mailboxes(accountId:) { id accountId name path totalCount unreadCount }`
- `mailMessages(input: MailSearchInput!)` metadata, pagination, recipients,
  flags, snippets, and file descriptors containing `downloadKey`, `kind`,
  `filename`, `mimeType`, and `byteSize`

No body or attachment bytes are materialized by this add-on.

### Authored Example

The shipped `examples/apple-mail-list/` bundle must stay read-only and validate
without a live Mail database or Full Disk Access:

```json
{
  "id": "list-apple-mail",
  "role": "worker",
  "addon": {
    "name": "riela/apple-mail-list",
    "version": "1",
    "config": {
      "first": 25
    },
    "inputs": {
      "accountId": "{{workflowInput.accountId}}",
      "mailboxId": "{{workflowInput.mailboxId}}",
      "query": "{{workflowInput.query}}",
      "unreadOnly": "{{workflowInput.unreadOnly}}",
      "flaggedOnly": "{{workflowInput.flaggedOnly}}",
      "after": "{{workflowInput.after}}"
    }
  }
}
```

### Configuration and Inputs

```typescript
interface AppleMailListAddonConfig {
  readonly binaryPath?: string;
  readonly accountId?: string;
  readonly mailboxId?: string;
  readonly query?: string;
  readonly from?: string;
  readonly to?: string;
  readonly subject?: string;
  readonly receivedAfter?: string;
  readonly receivedBefore?: string;
  readonly unreadOnly?: boolean;
  readonly flaggedOnly?: boolean;
  readonly first?: number;
  readonly after?: string;
}
```

Inputs use the same operation field names as config, except `binaryPath` is
ignored from inputs. Config values provide defaults; rendered `addon.inputs`
values provide per-run filters.

Defaults:

- `binaryPath`: literal `addon.config.binaryPath`, then
  `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through `PATH`
- `first`: `25`, bounded to `1...100`
- optional filters are omitted when unset or blank

Execution behavior:

1. reject unsupported versions and any authored `addon.env`
2. render supported config and input fields with the normal node template
   context
3. validate scalar filter types, booleans, and pagination bounds before
   spawning a process
4. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`; `binaryPath` is never sourced from
   workflow input, upstream payloads, or `addon.inputs`
5. run `apple-gateway graphql --query <rendered-query>` with separate process
   arguments and no shell interpolation
6. parse JSON stdout as a GraphQL envelope and preserve `extensions.requestId`
7. publish `appleMail.accounts`, `appleMail.mailboxes`,
   `appleMail.messages`, `appleMail.pageInfo`, `appleMail.totalCount`,
   `appleMail.permissions.mailFullDiskAccess`, and
   `appleGateway.binary`

### Validation and Error Rules

- version `1` only
- `addon.env` is rejected
- missing or non-executable binary maps to policy blocked
- invalid `first` and malformed booleans map to policy blocked before launch
- `permissions.mailFullDiskAccess` values `DENIED`, `NOT_DETERMINED`, or
  `UNKNOWN` map to policy blocked with guidance to grant Full Disk Access in
  System Settings > Privacy & Security
- GraphQL errors or stderr text that mention Full Disk Access, FDA, TCC,
  Mail permission, or database access denial map to policy blocked
- non-Full-Disk-Access GraphQL `errors` and non-zero process exits map to
  provider error
- malformed JSON, missing GraphQL `data`, or missing expected Mail fields map
  to invalid output
- deadline expiry terminates the subprocess and maps to timeout

## Built-in `riela/apple-mail-message`

### Purpose

`riela/apple-mail-message` retrieves one Mail message by id through
`apple-gateway` and can materialize selected body and attachment files from
gateway download keys into a Riela-controlled directory. It is read-only with
respect to Mail data: it does not send, mutate, delete, or mark messages.

Version `1` invokes the same fixed GraphQL transport as
`riela/apple-mail-list`:

```bash
apple-gateway graphql --query <rendered-query>
```

The fixed document reads `permissions { mailFullDiskAccess }` and
`mailMessage(messageId:)` with the same message metadata and file descriptor
shape as the list add-on.

### Authored Example

`riela/apple-mail-message` may appear in user-authored workflows that need local
message body or attachment paths. It is not used by the default read-only list
example:

```json
{
  "id": "get-apple-mail-message",
  "role": "worker",
  "addon": {
    "name": "riela/apple-mail-message",
    "version": "1",
    "config": {
      "materializeBodyText": true,
      "materializeAttachments": false
    },
    "inputs": {
      "messageId": "{{workflowInput.messageId}}"
    }
  }
}
```

### Configuration and Inputs

```typescript
interface AppleMailMessageAddonConfig {
  readonly binaryPath?: string;
  readonly messageId?: string;
  readonly materializeBodyText?: boolean;
  readonly materializeBodyHtml?: boolean;
  readonly materializeRawSource?: boolean;
  readonly materializeAttachments?: boolean;
  readonly maxDownloadBytes?: number;
  readonly downloadDir?: string;
}
```

Inputs may provide `messageId` only. `binaryPath`, `downloadDir`,
`materializeBodyText`, `materializeBodyHtml`, `materializeRawSource`,
`materializeAttachments`, and `maxDownloadBytes` are authored controls and are
never read from `addon.inputs`, workflow input, or upstream payloads.

Defaults:

- `messageId`: required from config or rendered inputs
- `materializeBodyText`: `true`
- `materializeBodyHtml`: `false`
- `materializeRawSource`: `false`
- `materializeAttachments`: `false`
- `maxDownloadBytes`: `26214400`
- `downloadDir`: literal `config.downloadDir`, then
  `APPLE_GATEWAY_DOWNLOAD_DIR`, then a Riela-owned temp directory under
  `<TMPDIR>/riela-apple-mail/<workflowId>/<nodeId>/<messageId>/`

Execution behavior:

1. reject unsupported versions and any authored `addon.env`
2. validate and render only `messageId`; validate materialization flags and byte
   limit from config only; read `downloadDir` only as literal config or
   environment fallback and never from rendered inputs or upstream payloads
3. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`
4. run `apple-gateway graphql --query <rendered-query>` with
   separate process arguments and no shell interpolation
5. if `data.mailMessage` is present and null, publish
   `appleMail.message = null`, `appleMail.found = false`, and
   `completionPassed = true`
6. when a message is found, validate `files` and selected descriptor containers,
   select descriptors according to materialization flags, and skip descriptors
   whose declared `byteSize` exceeds `maxDownloadBytes`
7. for each selected descriptor, invoke the fixed file download subcommand with
   separate arguments:

```bash
apple-gateway file download --key <download-key>
```

8. compare the actual stdout byte count to `maxDownloadBytes` before writing;
   underreported or missing provider `byteSize` values cannot bypass the cap
9. write downloaded bytes to a Riela-chosen leaf path under the download root;
   gateway-provided filenames are sanitized by stripping path separators,
   traversal markers, and control characters, with a deterministic fallback such
   as `<kind>-<index>`
10. publish `appleMail.message`, `appleMail.found`,
   `appleMail.materialized[]`, `appleMail.skippedDownloads[]`,
   `appleMail.downloadRoot`, `appleMail.permissions.mailFullDiskAccess`, and
   `appleGateway.binary`

The unresolved upstream contract for `apple-gateway file download` is tracked in
`design-docs/user-qa/qa-apple-mail-gateway-file-download.md`. Until confirmed,
implementation should prefer raw stdout bytes for the fake-executable contract.
If the real gateway requires an explicit output directory rather than stdout
bytes, Riela still chooses and validates the destination and passes that
Riela-controlled path to the gateway. The gateway never chooses the final local
path.

### Validation and Error Rules

- version `1` only
- `addon.env` is rejected
- missing `messageId`, invalid flags, invalid byte limit, missing binary, or
  non-executable binary maps to policy blocked
- `permissions.mailFullDiskAccess` values `DENIED`, `NOT_DETERMINED`, or
  `UNKNOWN` map to policy blocked with Full Disk Access guidance
- Full-Disk-Access markers in GraphQL errors, stderr, or file download failures
  map to policy blocked
- `data.mailMessage` present as `null` is a successful not-found result
- missing `data.mailMessage` key maps to invalid output
- non-Full-Disk-Access GraphQL errors, non-zero GraphQL exits, and non-zero file
  download exits map to provider error
- malformed JSON, missing GraphQL `data`, non-object message values,
  non-object `files`, non-object selected body descriptors, non-array
  `attachments` when attachment materialization is enabled, or non-object
  attachment descriptors map to invalid output
- sanitized materialized paths must remain under the chosen download root; path
  traversal attempts map to policy blocked before bytes are written
- actual downloaded stdout bytes larger than `maxDownloadBytes` are skipped
  before writing even when `byteSize` is absent or underreported
- deadline expiry terminates the subprocess and maps to timeout

### Security and Rollout Notes

Implementation must reuse the internal `apple-gateway` subprocess bridge used
by `riela/apple-notes-list`; process invocation, binary resolution, child
environment filtering, timeout handling, and stdout capture must not be
duplicated in the Mail implementation.

Tests must use fake `apple-gateway` executables only. Required coverage includes
account, mailbox, message list, and message get success paths; fixed GraphQL
query rendering; download-key materialization; filename
sanitization; byte-limit skip behavior; Full Disk Access denial mapping;
binary precedence; rejected `addon.env`; child environment filtering;
provider errors; malformed output; missing binary; and timeout handling without
live Mail access or Full Disk Access.

## Built-in `riela/x-gateway-read`

### Purpose

`riela/x-gateway-read` runs a read-only x-gateway GraphQL query in a
Docker-compatible container runner. It is intended for workflow nodes that need
to inspect X/Twitter state without embedding x-gateway-specific container
plumbing or credential forwarding in each workflow-local node payload.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. The runtime always invokes the read-only
`x-gateway-reader` binary from the configured container image. Workflow authors
cannot override that binary with the full `x-gateway` client.

### Authored Example

```json
{
  "id": "read-post",
  "role": "worker",
  "addon": {
    "name": "riela/x-gateway-read",
    "version": "1",
    "env": {
      "X_GW_TOKEN": {
        "fromEnv": "ACCOUNT_A_X_GW_TOKEN"
      }
    },
    "config": {
      "queryTemplate": "{ post(id: \"{{postId}}\") { id text } }",
      "image": "ghcr.io/tacogips/x-gateway:latest",
      "runnerKind": "docker"
    },
    "inputs": {
      "postId": "123"
    }
  }
}
```

### Configuration

```typescript
interface XGatewayReadAddonConfig {
  readonly queryTemplate: string;
  readonly image?: string;
  readonly runnerKind?: "podman" | "docker" | "nerdctl" | "container";
  readonly runnerPath?: string;
  readonly networkPolicy?: "disabled" | "egress-allowed";
}
```

Defaults:

- `image`: runtime default x-gateway image
- `runnerKind`: `workflow.defaults.containerRuntime.runnerKind` or `docker`
- `runnerPath`: `workflow.defaults.containerRuntime.runnerPath` or the runner
  kind executable name
- `networkPolicy`: runner default egress behavior

Execution behavior:

1. render `config.queryTemplate` with the normal node template context
2. resolve `addon.env` mappings from the riela runtime environment
3. run `x-gateway-reader graphql query <rendered-query> --json` in the
   configured container image
4. parse JSON stdout into the node payload under `xGateway`
5. attach stdout/stderr as process logs

Environment rules:

- `addon.env` is supported for this add-on because the descriptor consumes it
- target and source environment variable names must be valid environment names
- string shorthand means `{ "fromEnv": "<name>" }`
- object bindings may set `required: false`
- only mapped target environment variable names are passed to the container
  process; ambient host environment variables are not forwarded implicitly
- runtime readiness treats this add-on as a Docker-compatible container runner
  requirement, including inherited workflow-level runner defaults
- runtime readiness also reports each required `addon.env` source variable as an
  environment prerequisite; unset or empty required sources block readiness, and
  optional bindings with `required: false` do not block readiness or execution

Validation rules:

- `queryTemplate` is required and must render to a non-empty string
- `runnerKind` must be `podman`, `docker`, `nerdctl`, or `container`
- `networkPolicy` must be `disabled` or `egress-allowed`
- write and mutation surfaces are intentionally omitted from version `1`

## Built-in `riela/x-gateway`

### Purpose

`riela/x-gateway` runs an x-gateway GraphQL document in a Docker-compatible
container runner. It is intended for workflow nodes that intentionally need the
full x-gateway client surface, including post mutations such as creating X
posts, while still keeping credential forwarding explicit and scoped per add-on
node.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. The runtime always invokes the full `x-gateway` binary
from the configured container image. Workflow authors cannot override that
binary or supply an arbitrary command.

### Authored Example

```json
{
  "id": "post-to-x",
  "role": "worker",
  "addon": {
    "name": "riela/x-gateway",
    "version": "1",
    "env": {
      "X_GW_CONSUMER_KEY": {
        "fromEnv": "ACCOUNT_A_X_GW_CONSUMER_KEY"
      },
      "X_GW_CONSUMER_SECRET": {
        "fromEnv": "ACCOUNT_A_X_GW_CONSUMER_SECRET"
      },
      "X_GW_ACCESS_TOKEN": {
        "fromEnv": "ACCOUNT_A_X_GW_ACCESS_TOKEN"
      },
      "X_GW_ACCESS_TOKEN_SECRET": {
        "fromEnv": "ACCOUNT_A_X_GW_ACCESS_TOKEN_SECRET"
      }
    },
    "config": {
      "documentTemplate": "mutation { createPost(text: \"{{postText}}\") { id text } }",
      "image": "ghcr.io/tacogips/x-gateway:latest",
      "runnerKind": "docker"
    },
    "inputs": {
      "postText": "Hello from riela"
    }
  }
}
```

### Configuration

```typescript
interface XGatewayAddonConfig {
  readonly documentTemplate: string;
  readonly image?: string;
  readonly runnerKind?: "podman" | "docker" | "nerdctl" | "container";
  readonly runnerPath?: string;
  readonly networkPolicy?: "disabled" | "egress-allowed";
}
```

Defaults:

- `image`: runtime default x-gateway image
- `runnerKind`: `workflow.defaults.containerRuntime.runnerKind` or `docker`
- `runnerPath`: `workflow.defaults.containerRuntime.runnerPath` or the runner
  kind executable name
- `networkPolicy`: runner default egress behavior

Execution behavior:

1. render `config.documentTemplate` with the normal node template context
2. resolve `addon.env` mappings from the riela runtime environment
3. run `x-gateway graphql query <rendered-document> --json` in the configured
   container image
4. parse JSON stdout into the node payload under `xGateway`
5. attach stdout/stderr as process logs

Environment rules match `riela/x-gateway-read`: only explicitly mapped target
environment variable names are exposed to the container, required source
variables are runtime readiness prerequisites, and optional bindings may set
`required: false`.

Validation rules:

- `documentTemplate` is required and must render to a non-empty string
- `runnerKind` must be `podman`, `docker`, `nerdctl`, or `container`
- `networkPolicy` must be `disabled` or `egress-allowed`
- command or binary overrides are rejected; version `1` always runs
  `x-gateway`

## Built-in `riela/mail-gateway-read`

### Purpose

`riela/mail-gateway-read` runs a read-only mail-gateway GraphQL query in a
Docker-compatible container runner. It is intended for workflow nodes that need
to inspect configured mail accounts without embedding mail-gateway-specific
container plumbing or credential path forwarding in each workflow-local node
payload.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. The runtime always invokes the read-only
`mail-gateway-reader` binary from the configured container image. Workflow
authors cannot override that binary with the full `mail-gateway` client.

### Authored Example

```json
{
  "id": "read-mail",
  "role": "worker",
  "addon": {
    "name": "riela/mail-gateway-read",
    "version": "1",
    "env": {
      "MAIL_GATEWAY_CONFIG": {
        "fromEnv": "ACCOUNT_A_MAIL_GATEWAY_CONFIG"
      }
    },
    "config": {
      "queryTemplate": "{ message(accountId: \"{{accountId}}\", messageId: \"{{messageId}}\") { id subject } }",
      "image": "ghcr.io/tacogips/mail-gateway:latest",
      "runnerKind": "docker"
    },
    "inputs": {
      "accountId": "work",
      "messageId": "msg-123"
    }
  }
}
```

### Configuration

```typescript
interface MailGatewayReadAddonConfig {
  readonly queryTemplate: string;
  readonly image?: string;
  readonly runnerKind?: "podman" | "docker" | "nerdctl" | "container";
  readonly runnerPath?: string;
  readonly networkPolicy?: "disabled" | "egress-allowed";
}
```

Defaults:

- `image`: runtime default mail-gateway image
- `runnerKind`: `workflow.defaults.containerRuntime.runnerKind` or `docker`
- `runnerPath`: `workflow.defaults.containerRuntime.runnerPath` or the runner
  kind executable name
- `networkPolicy`: runner default egress behavior

Execution behavior:

1. render `config.queryTemplate` with the normal node template context
2. resolve `addon.env` mappings from the riela runtime environment
3. run `mail-gateway-reader graphql --query <rendered-query>` in the configured
   container image
4. parse JSON stdout into the node payload under `mailGateway`
5. attach stdout/stderr as process logs

Environment rules match the gateway add-ons above: only explicitly mapped target
environment variable names are exposed to the container, required source
variables are runtime readiness prerequisites, and optional bindings may set
`required: false`.

Validation rules:

- `queryTemplate` is required and must render to a non-empty string
- `runnerKind` must be `podman`, `docker`, `nerdctl`, or `container`
- `networkPolicy` must be `disabled` or `egress-allowed`
- send and mutation surfaces are intentionally omitted from version `1`

## Built-in `riela/mail-gateway`

### Purpose

`riela/mail-gateway` runs a mail-gateway GraphQL document in a
Docker-compatible container runner. It is intended for workflow nodes that
intentionally need the full mail-gateway client surface, including send
mutations such as `sendMessage`, while still keeping credential forwarding
explicit and scoped per add-on node.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. The runtime always invokes the full `mail-gateway` binary
from the configured container image. Workflow authors cannot override that
binary or supply an arbitrary command.

### Authored Example

```json
{
  "id": "send-mail",
  "role": "worker",
  "addon": {
    "name": "riela/mail-gateway",
    "version": "1",
    "env": {
      "MAIL_GATEWAY_CONFIG": {
        "fromEnv": "ACCOUNT_A_MAIL_GATEWAY_CONFIG"
      }
    },
    "config": {
      "documentTemplate": "mutation { sendMessage(input: { accountId: \"{{accountId}}\", to: [\"{{to}}\"], subject: \"{{subject}}\", textBody: \"{{body}}\" }) { message { id subject } } }",
      "image": "ghcr.io/tacogips/mail-gateway:latest",
      "runnerKind": "docker"
    },
    "inputs": {
      "accountId": "work",
      "to": "person@example.test",
      "subject": "Hello",
      "body": "Hello from riela"
    }
  }
}
```

### Configuration

```typescript
interface MailGatewayAddonConfig {
  readonly documentTemplate: string;
  readonly image?: string;
  readonly runnerKind?: "podman" | "docker" | "nerdctl" | "container";
  readonly runnerPath?: string;
  readonly networkPolicy?: "disabled" | "egress-allowed";
}
```

Defaults:

- `image`: runtime default mail-gateway image
- `runnerKind`: `workflow.defaults.containerRuntime.runnerKind` or `docker`
- `runnerPath`: `workflow.defaults.containerRuntime.runnerPath` or the runner
  kind executable name
- `networkPolicy`: runner default egress behavior

Execution behavior:

1. render `config.documentTemplate` with the normal node template context
2. resolve `addon.env` mappings from the riela runtime environment
3. run `mail-gateway graphql --query <rendered-document>` in the configured
   container image
4. parse JSON stdout into the node payload under `mailGateway`
5. attach stdout/stderr as process logs

Environment rules match `riela/mail-gateway-read`: only explicitly mapped
target environment variable names are exposed to the container, required source
variables are runtime readiness prerequisites, and optional bindings may set
`required: false`.

Validation rules:

- `documentTemplate` is required and must render to a non-empty string
- `runnerKind` must be `podman`, `docker`, `nerdctl`, or `container`
- `networkPolicy` must be `disabled` or `egress-allowed`
- command or binary overrides are rejected; version `1` always runs
  `mail-gateway`

### Reply Target Metadata

The event trigger layer should expose reply target data in
`runtimeVariables.event`.

Provider-specific event adapters normalize their incoming data into a
provider-neutral shape:

```typescript
interface EventReplyTarget {
  readonly sourceId: string;
  readonly provider: string;
  readonly eventId: string;
  readonly conversationId: string;
  readonly threadId?: string;
  readonly actorId?: string;
  readonly capabilities?: readonly ChatReplyCapability[];
}
```

Rules:

- credentials, channel secrets, and webhook signing data are never copied into
  `runtimeVariables.event`
- adapters may store provider raw payloads as event artifacts and expose only
  stable references
- missing reply target metadata is a configuration/runtime error unless
  `onMissingTarget` allows intent-only or dry-run behavior

### Reply Request

The executor submits this provider-neutral request:

```typescript
interface ChatReplyRequest {
  readonly target: EventReplyTarget;
  readonly message: {
    readonly text: string;
  };
  readonly visibility: "public" | "ephemeral";
  readonly idempotencyKey: string;
  readonly workflowId: string;
  readonly workflowExecutionId: string;
  readonly nodeId: string;
  readonly nodeExecId: string;
}
```

The idempotency key must be stable for the node execution. A retry of the same
node execution must not post duplicate chat messages.

### Output Contract

The add-on publishes an ordinary node output payload:

```json
{
  "reply": {
    "status": "sent",
    "target": {
      "sourceId": "web-chat",
      "provider": "web-chat",
      "conversationId": "thread-123"
    },
    "message": {
      "text": "The workflow result is ready."
    },
    "providerMessageId": "msg-456",
    "dispatchId": "reply-789"
  },
  "when": {
    "replied": true
  }
}
```

Allowed `reply.status` values:

- `sent`: provider dispatch completed successfully
- `queued`: provider adapter accepted the request for asynchronous delivery
- `intent-only`: the node produced a reply intent but did not dispatch it
- `dry-run`: no provider dispatch was attempted

Failure rules:

- provider rejection fails the node unless a future config explicitly allows
  best-effort replies
- an invalid rendered message fails the node
- duplicate dispatch for the same idempotency key must return the original
  dispatch result when the adapter can determine it

## Built-in `riela/calendar-*` and `riela/event-*`

### Purpose

The Apple Calendar add-ons expose the Calendar domain of a locally installed
`apple-gateway` CLI as seven fixed worker-only built-ins:

- `riela/calendar-list`: list calendars
- `riela/event-search`: search events in explicit calendars
- `riela/event-get`: read one event, including an optional occurrence date
- `riela/event-create`: create an event
- `riela/event-update`: update an event or recurrence span
- `riela/event-delete`: delete an event or recurrence span
- `riela/event-alarms-set`: replace event alarms or recurrence-span alarms

Each operation has its own add-on id and version `1`. Reads and mutations are
split by id so a read-only workflow cannot be changed into a destructive
Calendar operation through config, inputs, or upstream payload data. All seven
add-ons use the shared local CLI gateway rules, reuse the same apple-gateway
process runner and binary resolver as the Notes add-ons, and do not vendor
`apple-gateway`.

Version `1` always invokes GraphQL with a fixed document and typed variables:

```bash
apple-gateway graphql --query <fixed-document> --variables <json>
```

Calendar ids, event ids, text fields, recurrence `span`, `occurrenceDate`,
alarms, and recurrence rules travel only in the `--variables` JSON argument.
The GraphQL document is never built by interpolating user-controlled values.

### Authored Examples

The shipped runnable example should be read-only: list calendars, then fetch
upcoming events from explicit `workflowInput.calendarIds`.

```json
{
  "id": "list-calendars",
  "role": "worker",
  "addon": {
    "name": "riela/calendar-list",
    "version": "1",
    "config": {
      "entityType": "EVENT"
    }
  }
}
```

```json
{
  "id": "fetch-events",
  "role": "worker",
  "addon": {
    "name": "riela/event-search",
    "version": "1",
    "config": {
      "first": 25
    },
    "inputs": {
      "calendarIds": "{{workflowInput.calendarIds}}",
      "startDate": "{{workflowInput.startDate}}",
      "endDate": "{{workflowInput.endDate}}"
    }
  }
}
```

Mutation add-ons are cataloged and tested, but should appear only as
documentation snippets unless a future example is explicitly designed as
opt-in mutating:

```json
{ "name": "riela/event-create", "version": "1" }
{ "name": "riela/event-update", "version": "1" }
{ "name": "riela/event-delete", "version": "1" }
{ "name": "riela/event-alarms-set", "version": "1" }
```

### Configuration and Inputs

Common rules:

- `binaryPath` is config-only, literal, and resolved before
  `APPLE_GATEWAY_BIN`, then `PATH`
- `binaryPath` is never rendered from workflow input, upstream payloads, or
  `addon.inputs`
- `addon.config` is literal and is not rendered with the template context
- supported `addon.inputs` fields are rendered once with the normal node
  template context, then merged over `addon.config` before variables JSON is
  produced
- `addon.inputs` values override same-named config values; arbitrary runtime
  variables and `resolvedInputPayload` keys are ignored unless the add-on
  author explicitly binds them through `addon.inputs`
- rendered input string scalars are treated as literal values after the first
  render; structured arrays and objects pass through as JSON values
- `addon.env` is rejected for all seven Calendar add-ons

```typescript
interface CalendarListAddonConfig {
  readonly binaryPath?: string;
  readonly entityType?: "EVENT" | "REMINDER";
}

interface EventSearchAddonConfig {
  readonly binaryPath?: string;
  readonly calendarIds?: string[];
  readonly startDate?: string;
  readonly endDate?: string;
  readonly query?: string;
  readonly first?: number;
  readonly after?: string;
}

interface EventGetAddonConfig {
  readonly binaryPath?: string;
  readonly eventId?: string;
  readonly occurrenceDate?: string;
}

interface EventCreateAddonConfig {
  readonly binaryPath?: string;
  readonly calendarId?: string;
  readonly title?: string;
  readonly startDate?: string;
  readonly endDate?: string;
  readonly isAllDay?: boolean;
  readonly notes?: string;
  readonly location?: string;
  readonly url?: string;
  readonly timeZone?: string;
  readonly availability?: EventAvailability;
  readonly alarms?: AlarmInput[];
  readonly recurrenceRules?: RecurrenceRuleInput[];
}

interface EventUpdateAddonConfig {
  readonly binaryPath?: string;
  readonly eventId?: string;
  readonly span?: RecurrenceSpan;
  readonly occurrenceDate?: string;
  readonly title?: string;
  readonly startDate?: string;
  readonly endDate?: string;
  readonly isAllDay?: boolean;
  readonly notes?: string;
  readonly location?: string;
  readonly url?: string;
  readonly timeZone?: string;
  readonly availability?: EventAvailability;
  readonly calendarId?: string;
  readonly alarms?: AlarmInput[];
  readonly recurrenceRules?: RecurrenceRuleInput[];
}

interface EventDeleteAddonConfig {
  readonly binaryPath?: string;
  readonly eventId?: string;
  readonly span?: RecurrenceSpan;
  readonly occurrenceDate?: string;
}

interface EventAlarmsSetAddonConfig {
  readonly binaryPath?: string;
  readonly eventId?: string;
  readonly alarms?: AlarmInput[];
  readonly span?: RecurrenceSpan;
  readonly occurrenceDate?: string;
}
```

`EventAvailability` accepts `NOT_SUPPORTED`, `BUSY`, `FREE`, `TENTATIVE`, and
`UNAVAILABLE`. `RecurrenceSpan` accepts `THIS_EVENT` and `FUTURE_EVENTS`.
`AlarmInput` accepts `relativeOffsetSeconds` or `absoluteDate`. Recurrence-rule
objects are forwarded as typed variables after enum and JSON-shape validation.

Defaults:

- `binaryPath`: `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through
  `PATH`
- `calendar-list.entityType`: `EVENT`
- `event-search.first`: `25`, bounded to `1...100`
- `event-create.isAllDay`: `false`
- `event-update.span`, `event-delete.span`, and `event-alarms-set.span`:
  `THIS_EVENT`

### Execution Behavior

All seven add-ons:

1. reject unsupported versions and any authored `addon.env`
2. merge literal `addon.config` with rendered `addon.inputs` only, with
   `addon.inputs` overriding config and unrelated runtime variables ignored
3. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`
4. run `apple-gateway graphql --query <fixed-document> --variables <json>` with
   separate process arguments and no shell interpolation
5. parse JSON stdout as a GraphQL envelope, preserving `extensions.requestId`
6. publish `status`, `addon`, `stepId`, `appleGateway.binary`,
   `appleGateway.requestId`, and `appleGateway.rawData`

Fixed operation fields:

- `calendar-list`: `calendars(entityType:)`
- `event-search`: `events(input:)`
- `event-get`: `event(eventId:, occurrenceDate:)`
- `event-create`: `createEvent(input:)`
- `event-update`: `updateEvent(input:)`
- `event-delete`: `deleteEvent(eventId:, span:, occurrenceDate:)`
- `event-alarms-set`: `setEventAlarms(eventId:, alarms:, span:, occurrenceDate:)`

Calendar output:

- `calendar-list`: `appleCalendar.calendars`, `calendarCount`
- `event-search`: `appleCalendar.events`, `pageInfo`, `totalCount`
- `event-get`: `appleCalendar.event`; `when.has_event`
- `event-create`: `appleCalendar.event`; `when.has_event`, `when.created`
- `event-update`: `appleCalendar.event`; `when.has_event`, `when.updated`
- `event-delete`: `appleCalendar.deleteResult`, `deleted`; `when.deleted`
- `event-alarms-set`: `appleCalendar.event`; `when.has_event`, `when.alarms_set`

Event selections should include identity, calendar id, title, notes, location,
URL, all-day flag, start/end dates, time zone, status, availability, organizer,
attendees, alarms, recurrence rules, recurring/detached flags, occurrence date,
creation date, and last modified date. Search wraps selected events in cursor
edges and preserves page info.

### Validation and Error Rules

- version `1` only
- `addon.env` is rejected
- `calendarIds` is required and non-empty for event search
- `eventId` is required for get, update, delete, and alarms-set
- `title`, `startDate`, and `endDate` are required for create
- `alarms` is required for alarms-set; an empty array is allowed to clear alarms
- `entityType`, `availability`, recurrence frequency values, and `span` must be
  known enum values
- `event-search.first` must be between `1` and `100`
- missing or non-executable binary maps to policy blocked
- required input missing or invalid enum/value maps to policy blocked
- non-zero process exit maps to provider error
- GraphQL `errors` map to provider error and preserve upstream messages and
  extension codes
- malformed or non-UTF8 JSON, missing GraphQL `data`, or a missing expected
  operation field maps to invalid output
- `event-delete` requires `data.deleteEvent.success` to be a boolean; missing
  or non-boolean values map to invalid output
- deadline expiry terminates the subprocess and maps to timeout

### Security and Rollout Notes

Implementation reuses the existing internal `apple-gateway` support file used
by `riela/apple-notes-list` and the Notes CRUD add-ons, then adds Calendar read
and mutation executors split by responsibility. Process invocation logic must
not be duplicated across Notes and Calendar.

Tests must use fake `apple-gateway` executables only. The required matrix covers
argument shape, variables JSON, config-over-env-over-`PATH` binary precedence,
runtime environment filtering, provider errors, non-zero exits, malformed JSON,
missing data, timeout, rejected `addon.env`, unsupported versions, and
operation-specific validation. The injection test must prove user-controlled
event text, ids, alarms, and recurrence data appear only in `--variables`, not
in `--query`.

The `examples/apple-calendar-fetch` bundle must remain read-only. It may list
calendars and fetch events, but must not create, update, delete, move, or alter
alarms. Live Apple Calendar access is not required for tests or validation.


## Built-in `riela/apple-clock-alarm-*`

### Purpose

The Apple Clock Alarms add-ons expose the `apple-gateway` Clock alarms domain
as five fixed-shape worker add-ons:

- `riela/apple-clock-alarms-list`: list existing alarms
- `riela/apple-clock-alarm-create`: create an alarm
- `riela/apple-clock-alarm-toggle`: enable or disable an alarm
- `riela/apple-clock-alarm-update`: update an alarm's time, label, or repeat
  days
- `riela/apple-clock-alarm-delete`: delete an alarm

Each operation has its own add-on id and version `1`. Workflow authors cannot
provide arbitrary GraphQL; every add-on runs exactly one operation through the
shared local CLI gateway rules. The list add-on is read-only. The create,
toggle, update, and delete add-ons are mutation-capable and must be documented
as operational actions that can change the user's Clock data.

Version `1` invokes the local `apple-gateway` binary with separate process
arguments:

```bash
apple-gateway graphql --query <fixed-document>
apple-gateway graphql --query <fixed-document> --variables <json>
```

The list operation uses only `--query`. Mutation inputs are sent through the
`--variables` JSON argument and are never interpolated into the GraphQL
document. If `apple-gateway` rejects `--variables` or exits nonzero after a
mutation request, Riela fails closed and does not issue a second mutation
attempt. Confirmation of upstream `graphql --variables` support remains tracked in
`design-docs/user-qa/qa-apple-clock-alarm-gateway-confirmations.md`.

### Authored Example

The shipped example must be read-only and list alarms:

```json
{
  "id": "list-clock-alarms",
  "role": "worker",
  "addon": {
    "name": "riela/apple-clock-alarms-list",
    "version": "1",
    "config": {},
    "inputs": {}
  }
}
```

Mutation add-ons are documented as explicit opt-in snippets only:

```json
{ "name": "riela/apple-clock-alarm-create", "version": "1" }
{ "name": "riela/apple-clock-alarm-toggle", "version": "1" }
{ "name": "riela/apple-clock-alarm-update", "version": "1" }
{ "name": "riela/apple-clock-alarm-delete", "version": "1" }
```

### Configuration, Inputs, and Outputs

```typescript
interface AppleClockAlarmAddonConfig {
  readonly binaryPath?: string;
}
```

Inputs:

- `riela/apple-clock-alarms-list`: no operation inputs
- `riela/apple-clock-alarm-create`: required `time` in `HH:mm` 24-hour format,
  optional `label`, optional `repeatDays`
- `riela/apple-clock-alarm-toggle`: required `label`, optional `enabled`
- `riela/apple-clock-alarm-update`: required `label`, optional `time`, optional
  `newLabel`, optional `repeatDays`
- `riela/apple-clock-alarm-delete`: required `label`

Defaults:

- `binaryPath`: `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through
  `PATH`
- `repeatDays`: omitted unless authored
- `enabled`: omitted unless authored so the upstream gateway can apply its
  operation default

`repeatDays` accepts either a JSON string array or a comma-separated string.
Tokens are trimmed, uppercased, and validated against the fixed GraphQL enum set
`MONDAY`, `TUESDAY`, `WEDNESDAY`, `THURSDAY`, `FRIDAY`, `SATURDAY`, and
`SUNDAY` before the subprocess is launched.

List output:

- `payload.clockAlarms`: array of alarms with `id`, `label`, `time`,
  `isEnabled`, and `repeatDays`
- `payload.alarmCount`
- `replyText`
- `appleGateway.binary`, `appleGateway.requestId`, and bounded
  `appleGateway.rawData`
- `when.always: true` and `when.has_alarms`

Mutation output:

- `payload.clockAlarm`: the returned alarm object when present
- `payload.result.success`
- `payload.result.warning`
- `replyText`
- `appleGateway.binary`, `appleGateway.requestId`, and bounded
  `appleGateway.rawData`
- `when.always: true` and `when.succeeded` derived from
  `payload.result.success`

### Execution Behavior

All five add-ons:

1. reject unsupported versions and any authored `addon.env`
2. render supported config and input fields with the normal node template
   context
3. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`; `binaryPath` is never sourced from
   workflow input, upstream payloads, or `addon.inputs`
4. run the fixed `apple-gateway graphql` command with separate process
   arguments and no shell interpolation
5. parse JSON stdout as a GraphQL envelope, preserving `extensions.requestId`
6. publish bounded process provenance, including the resolved binary source and
   host OS version, without forwarding or exposing secret-like environment
   values

Operation-specific GraphQL:

- list runs fixed query `clockAlarms { id label time isEnabled repeatDays }`
- create runs fixed mutation `createClockAlarm(input: $input)`
- toggle runs fixed mutation `toggleClockAlarm(input: $input)`
- update runs fixed mutation `updateClockAlarm(input: $input)`
- delete runs fixed mutation `deleteClockAlarm(input: $input)`

### Shortcuts Bridge and macOS Requirements

All five operations depend on the `apple-gateway` Shortcuts Clock bridge and the
`shortcutsClockBridge` permission. Operators must install the required
Shortcuts from `apple-gateway`'s `packaging/shortcuts` directory:

- `apple-gateway-get-alarms`
- `apple-gateway-create-alarm`
- `apple-gateway-toggle-alarm`
- `apple-gateway-update-alarm`
- `apple-gateway-delete-alarm`

The example README must tell operators to verify readiness with
`apple-gateway permissions status --json`. Missing bridge failures are surfaced
as policy-blocked errors that name the missing shortcut family and the
`packaging/shortcuts` installation step.

`riela/apple-clock-alarm-update` and `riela/apple-clock-alarm-delete` require
macOS 26 or newer. The upstream `apple-gateway` owns OS-version enforcement so
Riela does not duplicate host-version policy. When the gateway reports an
unsupported OS envelope, these add-ons map it to a policy-blocked error that
states the operation requires macOS 26+.

### Validation and Error Rules

- version `1` only
- `addon.env` is rejected
- missing or non-executable binary maps to policy blocked
- missing required inputs, invalid `time`, invalid weekday tokens, and non-bool
  `enabled` map to policy blocked
- process start failure, non-zero process exit, generic GraphQL `errors`, and
  `ClockAlarmResult.success == false` with a warning map to provider error
- GraphQL errors classified as a missing Shortcuts bridge map to policy blocked
  and mention the required alarm Shortcuts installation path
- GraphQL errors classified as OS-version gating for update or delete map to
  policy blocked and mention macOS 26+
- malformed JSON, missing GraphQL `data`, missing expected operation fields, or
  unexpected result shape maps to invalid output
- deadline expiry terminates the subprocess process group and maps to timeout

The error classifier prefers upstream `errors[].extensions.code` values such as
`SHORTCUT_BRIDGE_MISSING` and `UNSUPPORTED_OS_VERSION` when present, then falls
back to bounded case-insensitive message token matching. Provider messages and
extension codes are preserved as diagnostics, but secret-like environment
values and full ambient process environments are never included in node output.
The exact missing Shortcuts bridge envelope, unsupported macOS envelope, and
Clock time format are intentionally held in
`design-docs/user-qa/qa-apple-clock-alarm-gateway-confirmations.md` until local
upstream behavior is confirmed; implementation should update fake fixtures and
classifier tokens from that evidence.

### Security and Rollout Notes

The implementation must reuse the shared `apple-gateway` subprocess bridge used
by `riela/apple-notes-list` and the Apple Notes CRUD add-ons. Process
invocation, pipe draining, timeout cleanup, binary resolution, and environment
allowlisting should live in one shared support path rather than being copied
into Clock-specific executors.

Tests must use fake `apple-gateway` executables only. The required matrix covers
list, create, toggle, update, and delete success paths; fixed query and
`--variables` argument construction; missing Shortcuts bridge; macOS 26+
gating for update and delete; validation failures; provider errors; malformed
output; timeout; executable precedence; `binaryPath` not being sourced from
inputs or upstream payloads; and stripping secret-like runtime environment
variables.

Only the read-only `examples/apple-clock-alarms-list` bundle should be shipped
as a runnable default example. Mutation operations can appear in catalog
documentation and tests, but default examples must not delete, overwrite, or
toggle user Clock data.


## Built-in `riela/apple-gateway-*` Admin CLI Add-ons

### Purpose

The apple-gateway admin add-ons expose fixed `apple-gateway` CLI subcommands
without giving workflow authors arbitrary process execution. They are
worker-only, version `1`, and use one add-on id per operation so the catalog can
mark read-only, state-changing, disk-writing, and unrestricted operations
independently:

- `riela/apple-gateway-graphql`: unrestricted GraphQL passthrough and catch-all
  escape hatch for gateway capabilities without a dedicated add-on
- `riela/apple-gateway-schema`: read-only schema printing
- `riela/apple-gateway-permissions-status`: read-only permission status
- `riela/apple-gateway-permissions-request`: STATE-CHANGING OS permission
  request prompt
- `riela/apple-gateway-config-validate`: read-only config validation
- `riela/apple-gateway-file-download`: writes files to the local filesystem
- `riela/apple-gateway-cache-prune`: STATE-CHANGING cache deletion

All seven add-ons reuse the same local CLI gateway rules as
`riela/apple-notes-list`: process invocation is centralized in the
apple-gateway bridge, arguments are passed as separate argv elements with no
shell interpolation, `addon.env` is rejected, and the executable resolves from
literal `addon.config.binaryPath`, then `APPLE_GATEWAY_BIN`, then `PATH`.
`binaryPath` is never rendered from workflow input, upstream payloads, or
`addon.inputs`.

Every successful payload carries `status`, `addon`, `stepId`, and
`appleGateway.binary` with the resolved executable path and source. Deadline
expiry terminates the subprocess and maps to timeout.

### Admin Add-on Inputs and Precedence

For all seven admin add-ons, supported `addon.inputs` fields are rendered with
the normal node template context and override or supplement matching
`addon.config` fields. `binaryPath` is the only exception: it is config-only,
read literally from `addon.config.binaryPath`, and is never sourced from
`addon.inputs`, workflow variables, workflow input, or upstream payloads.

Supported `addon.inputs` fields by add-on:

- `riela/apple-gateway-graphql`: `config`, `configPath`, `query`,
  `queryFile`, `variables`, `variablesFile`
- `riela/apple-gateway-schema`: `role`
- `riela/apple-gateway-permissions-status`: no operation inputs
- `riela/apple-gateway-permissions-request`: `domain`
- `riela/apple-gateway-config-validate`: `config`, `configPath`
- `riela/apple-gateway-file-download`: `keys`, `outputDir`
- `riela/apple-gateway-cache-prune`: `all`

When both `config` and `configPath` are present, `configPath` is the effective
config path. When both `query` and `queryFile` are present,
`queryFile` is the effective query source. When both `variables` and
`variablesFile` are present, `variablesFile` is the effective variables source.

### `riela/apple-gateway-graphql`

The GraphQL passthrough add-on invokes:

```bash
apple-gateway [--config <path>] graphql (--query <text> | --query-file <path>) [--variables <json> | --variables-file <path>]
```

It is intentionally unrestricted and can forward arbitrary documents, including
mutations. It is the documented catch-all escape hatch when no narrower built-in
add-on exists, so workflows using it need the same review as direct
apple-gateway GraphQL access.

Authored example:

```json
{
  "id": "gateway-query",
  "role": "worker",
  "addon": {
    "name": "riela/apple-gateway-graphql",
    "version": "1",
    "config": {
      "query": "{ noteAccounts { id name isDefault } }"
    }
  }
}
```

Configuration and inputs:

```typescript
interface AppleGatewayGraphQLAddonConfig {
  readonly binaryPath?: string;
  readonly config?: string;
  readonly configPath?: string;
  readonly query?: string;
  readonly queryFile?: string;
  readonly variables?: Record<string, unknown> | string;
  readonly variablesFile?: string;
}
```

Inputs and precedence:

- supported `addon.inputs` fields: `config`, `configPath`, `query`,
  `queryFile`, `variables`, `variablesFile`
- `binaryPath` is config-only and cannot be supplied through inputs, variables,
  workflow input, or upstream payloads
- `configPath` takes precedence over `config`; the effective path is prepended
  before `graphql`
- `queryFile` takes precedence over `query`
- `variablesFile` takes precedence over `variables`
- `variables` accepts a JSON object compact-serialized to `--variables` or a
  rendered JSON string passed as `--variables`

Outputs:

- parses the upstream GraphQL envelope
- non-empty `errors` maps to provider error
- publishes `appleGateway.data`, `appleGateway.extensions`,
  `appleGateway.requestId`, and top-level `replyText`

Validation and error rules:

- version `1` only
- at least one query source is required; missing both `query` and `queryFile`
  maps to policy blocked
- when both query sources are present, `queryFile` takes precedence over
  `query`
- `variablesFile` takes precedence over `variables`
- malformed JSON or missing GraphQL `data` maps to invalid output
- non-zero process exit maps to provider error

### `riela/apple-gateway-schema`

The schema add-on invokes:

```bash
apple-gateway schema print [--role full|reader]
```

It is read-only.

Configuration:

```typescript
interface AppleGatewaySchemaAddonConfig {
  readonly binaryPath?: string;
  readonly role?: "full" | "reader";
}
```

Inputs and precedence:

- supported `addon.inputs` field: `role`
- `binaryPath` is config-only and cannot be supplied through inputs, variables,
  workflow input, or upstream payloads
- `addon.inputs.role`, when present, overrides `addon.config.role`

Outputs:

- publishes `appleGateway.role`, `appleGateway.schemaSDL`, and
  `appleGateway.byteCount`

Validation and error rules:

- version `1` only
- `role`, when present, must be `full` or `reader`
- empty stdout maps to invalid output
- non-zero process exit maps to provider error

### `riela/apple-gateway-permissions-status`

The permissions status add-on invokes:

```bash
apple-gateway permissions status --json
```

It is read-only and intended for examples and operational readiness checks.

Configuration:

```typescript
interface AppleGatewayPermissionsStatusAddonConfig {
  readonly binaryPath?: string;
}
```

Inputs and precedence:

- supported `addon.inputs` fields: none
- `binaryPath` is config-only and cannot be supplied through inputs, variables,
  workflow input, or upstream payloads

Outputs:

- decodes stdout as a JSON object
- publishes `appleGateway.permissions`

Validation and error rules:

- version `1` only
- non-JSON or non-object stdout maps to invalid output
- non-zero process exit maps to provider error

### `riela/apple-gateway-permissions-request`

The permissions request add-on invokes:

```bash
apple-gateway permissions request --domain <calendar|reminders|notes|notifications>
```

It is STATE-CHANGING because it can drive macOS TCC permission prompts. It must
not be used by the read-only example bundle.

Configuration:

```typescript
interface AppleGatewayPermissionsRequestAddonConfig {
  readonly binaryPath?: string;
  readonly domain?: "calendar" | "reminders" | "notes" | "notifications";
}
```

Inputs and precedence:

- supported `addon.inputs` field: `domain`
- `binaryPath` is config-only and cannot be supplied through inputs, variables,
  workflow input, or upstream payloads
- `addon.inputs.domain`, when present, overrides `addon.config.domain`

Outputs:

- publishes `appleGateway.domain`
- publishes `appleGateway.result` as decoded JSON when stdout is JSON, otherwise
  bounded raw stdout

Validation and error rules:

- version `1` only
- `domain` is required and must be one of the allowed domains
- non-zero process exit maps to provider error

### `riela/apple-gateway-config-validate`

The config validate add-on invokes:

```bash
apple-gateway config validate [--config <path>]
```

It is read-only.

Configuration:

```typescript
interface AppleGatewayConfigValidateAddonConfig {
  readonly binaryPath?: string;
  readonly config?: string;
  readonly configPath?: string;
}
```

Inputs and precedence:

- supported `addon.inputs` fields: `config`, `configPath`
- `binaryPath` is config-only and cannot be supplied through inputs, variables,
  workflow input, or upstream payloads
- `configPath` takes precedence over `config`

Outputs:

- exit `0` publishes `appleGateway.valid: true`
- publishes optional `appleGateway.configPath` and bounded
  `appleGateway.output`

Validation and error rules:

- version `1` only
- non-zero process exit maps to provider error and carries bounded stderr

### `riela/apple-gateway-file-download`

The file download add-on invokes:

```bash
apple-gateway file download --key <key> [--key <key> ...] [--output-dir <dir>]
```

It writes files to the local filesystem. Callers must choose an explicit,
reviewed output location when they do not want apple-gateway defaults.

Configuration:

```typescript
interface AppleGatewayFileDownloadAddonConfig {
  readonly binaryPath?: string;
  readonly keys?: string[];
  readonly outputDir?: string;
}
```

Inputs and precedence:

- supported `addon.inputs` fields: `keys`, `outputDir`
- `binaryPath` is config-only and cannot be supplied through inputs, variables,
  workflow input, or upstream payloads
- `addon.inputs.keys`, when present, overrides `addon.config.keys`
- `addon.inputs.outputDir`, when present, overrides `addon.config.outputDir`

Outputs:

- publishes `appleGateway.keys` and optional `appleGateway.outputDir`
- publishes `appleGateway.result` as a decoded JSON manifest when stdout is
  JSON, otherwise bounded raw stdout

Validation and error rules:

- version `1` only
- at least one key is required
- each `keys` entry and `outputDir`, when present, is template-rendered
- non-zero process exit maps to provider error

### `riela/apple-gateway-cache-prune`

The cache prune add-on invokes:

```bash
apple-gateway cache prune [--all]
```

It is STATE-CHANGING because it deletes apple-gateway cache data.

Configuration:

```typescript
interface AppleGatewayCachePruneAddonConfig {
  readonly binaryPath?: string;
  readonly all?: boolean;
}
```

Inputs and precedence:

- supported `addon.inputs` field: `all`
- `binaryPath` is config-only and cannot be supplied through inputs, variables,
  workflow input, or upstream payloads
- `addon.inputs.all`, when present, overrides `addon.config.all`

Outputs:

- publishes `appleGateway.all`
- publishes `appleGateway.result` as decoded JSON when stdout is JSON, otherwise
  bounded raw stdout

Validation and error rules:

- version `1` only
- `all`, when present, must be boolean
- non-zero process exit maps to provider error

### Admin CLI Test and Example Requirements

Tests must use fake `apple-gateway` executables only. Required coverage includes
argv construction for every subcommand, config-to-env-to-`PATH` binary
precedence, proof that `binaryPath` cannot be sourced from inputs, upstream
payloads, or variables, rejected `addon.env`, minimal child environment
forwarding, unsupported versions, timeout handling, output parsing, malformed
output, non-zero exits, and operation-specific validation errors.

The `examples/apple-gateway-admin` bundle must stay read-only: it may call
`riela/apple-gateway-permissions-status` and
`riela/apple-gateway-graphql` with a read-only query, but must not use
`riela/apple-gateway-permissions-request`,
`riela/apple-gateway-file-download`, or `riela/apple-gateway-cache-prune`.

## Packaging Coverage Decision

Apple Gateway packaging remains documentation-only Riela coverage. No new
built-in add-on id is accepted for packaging, and no resolver, catalog,
execution-contract, or `AppleGatewayProcessRunner` changes are required.

| Packaging item | Accepted shape | Rationale |
| --- | --- | --- |
| Dry-run packaging plan (`task build:homebrew -- --dry-run`, `task build:homebrew-cask -- --dry-run`) | Command-node recipe through a JSONL wrapper plus one read-only example bundle | Credential-free and read-only, but raw `task` output is human-oriented `key: value` plan text. A command node must invoke a wrapper/mock that captures the raw output and emits one JSON object on stdout. |
| Formula archive build (`task build:homebrew`) | Command-node recipe through a JSONL wrapper, documented for human or CI use | Builds and stages archives with unstructured process output and no Apple signing credentials. It is project build tooling, not a runtime gateway capability, so stdout must be normalized by the wrapper before Riela consumes it. |
| Signed/notarized cask and release (`task build:homebrew-cask`, `task release:homebrew-cask-local`) | Documentation-only human-run commands outside Riela | Requires local Apple signing credentials, notarization, a keychain identity, and release publishing side effects. |
| GitHub Actions (`gitleaks.yml`, `linux-amd64-build.yml`) | Reference note only | These run in GitHub-hosted CI, not as local Riela behavior. Local analogs are `task lint` and `task build`. |

Packaging tasks are repository build and release tooling. They run `task` or
repo scripts and produce build logs or plan text. They do not satisfy the shared
local CLI gateway contract above, which is intentionally limited to fixed
`apple-gateway graphql` invocations with separate process arguments and valid
GraphQL JSON stdout. They also cannot be executed as raw Riela command nodes:
command-node stdout is parsed as JSONL and may contain at most one JSON object
record. The accepted Riela shape is therefore a command node that invokes a
small wrapper or deterministic mock. The wrapper runs the underlying `task`
target, captures raw stdout/stderr internally, redacts credential-looking
values, and emits exactly one JSON object on stdout with fields such as
`target`, `dryRun`, `exitCode`, `planText`, `stdoutSummary`, and
`sideEffects`. Raw `task ...` invocations remain shell documentation, not
copy-paste Riela node payloads.

The rejected alternative is a `riela/apple-gateway-packaging-plan` built-in
add-on wrapping a whitelist of dry-run task targets. That shape would not reuse
the shared Apple Gateway bridge: it would resolve `task` rather than
`apple-gateway`, require checkout-directory configuration instead of
`binaryPath`, and parse unstructured `key: value` output rather than the
GraphQL envelope. The marginal safety improvement over a command node does not
justify a divergent bridge or a new catalog id.

### Signing Credentials Never Enter Riela

Real Homebrew Cask build and release commands require
`APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID`,
plus a Developer ID Application identity installed in the local macOS keychain.
The evidence is in `scripts/build-homebrew-cask-release.sh`, where dry-run
`print_plan` emits the required environment names but real `build_target` calls
`require_env` for those values before codesigning and notarization, and in
`scripts/release-homebrew-cask-local.sh`, which documents the same environment
and keychain requirements before invoking the cask build and release upload.

Those credential values must live only in the user's kinko-managed shell
environment and macOS keychain. They must never be copied into workflow JSON,
add-on config, node inputs, example files, or logs. Human-run signed cask and
release commands stay outside Riela:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task build:homebrew-cask -- darwin-arm64 darwin-x64

kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v<version>
```

Dry-run packaging plans and formula archive builds do not need Apple signing
credentials. The dry-run cask path reaches `print_plan` instead of the real
signing/notarization path, and formula archive builds do not use Apple
notarization credentials. However, local command execution currently inherits
the Riela process environment and merges explicit node environment over it. If
Riela itself is launched inside a kinko shell, Apple credential variables can be
present in the command child environment even when the node JSON does not name
them. Operators must run Riela packaging-plan workflows outside any
credential-bearing kinko shell. The wrapper used by real command-node recipes
must also fail closed or invoke `task` through an environment scrubber that
removes `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, and
`APPLE_TEAM_ID` before the task process starts. Authors must never place those
values in workflow JSON, node inputs, add-on config, or logs.

### Command-node Recipe: Dry-run Packaging Plan

This is the accepted automatable shape. It is read-only and does not publish,
delete, overwrite, sign, notarize, upload, or require live Apple app access.
The real checkout path is a workflow input, not a committed absolute path.

```json
{
  "id": "packaging-plan",
  "nodeType": "command",
  "variables": {
    "appleGatewayCheckout": "{{workflowInput.appleGatewayCheckout}}"
  },
  "command": {
    "scriptPath": "scripts/task-jsonl-wrapper.sh",
    "argvTemplate": [
      "{{workflowInput.appleGatewayCheckout}}",
      "build:homebrew-cask",
      "--",
      "--dry-run"
    ],
    "envTemplate": {},
    "workingDirectory": "scripts"
  },
  "output": {
    "description": "Homebrew cask dry-run plan: targets, versions, artifact names; no credentials, no publish."
  }
}
```

`task-jsonl-wrapper.sh` is workflow-owned glue, not a new built-in add-on. It
is resolved from the workflow bundle's `scripts/` directory, not from the
external Apple Gateway checkout. The checkout path is passed as the first
rendered argument. The wrapper must validate that path before use, reject empty
or non-directory values, avoid shell interpolation, scrub
`APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID`
from the child environment, `cd` to the validated checkout itself, run `task`
with the remaining arguments, capture raw human-readable output, and print one
JSON object line. Use `["{{workflowInput.appleGatewayCheckout}}",
"build:homebrew", "--", "--dry-run"]` for the formula dry-run plan when that
target supports dry-run output in the selected checkout.

The checked-in example bundle should default to a mock command node, using
`scriptPath`/`argvTemplate`/`envTemplate` authoring aliases like
`examples/node-combinations-showcase`, so `riela workflow validate
apple-gateway-packaging-plan --workflow-definition-dir examples` does not
require a real checkout, `task`, Apple app access, or credentials. The mock
script must emit one JSON object line containing the representative plan text;
printing the raw plan block directly to stdout is invalid for command-node
execution. Successful validation of the mock bundle proves only the documented
bundle shape and JSONL contract; it does not prove the real Apple Gateway
checkout recipe until a wrapper-shaped command is smoke-tested with a real
checkout path.

### Command-node Recipe: Formula Archive Build

Formula archive builds are allowed as a command-node recipe for human or CI use
when the caller intentionally wants to compile and stage artifacts. They remain
outside the Apple Gateway built-in catalog.

```json
{
  "id": "formula-archive-build",
  "nodeType": "command",
  "variables": {
    "appleGatewayCheckout": "{{workflowInput.appleGatewayCheckout}}"
  },
  "command": {
    "scriptPath": "scripts/task-jsonl-wrapper.sh",
    "argvTemplate": [
      "{{workflowInput.appleGatewayCheckout}}",
      "build:homebrew"
    ],
    "envTemplate": {},
    "workingDirectory": "scripts"
  },
  "output": {
    "description": "Homebrew formula archive build output, including built archive paths and checksums."
  }
}
```

As with the dry-run plan, the wrapper owns stdout normalization. The underlying
`task build:homebrew` output may include progress text, `built <archive>` lines,
and checksums, but Riela receives only the wrapper's single JSONL record. Do not
replace the wrapper-owned `scriptPath` with a checkout-relative executable, and
do not put `{{workflowInput.appleGatewayCheckout}}` in `command.workingDirectory`;
Riela does not render that field at command execution time.

### Command-node Recipe: Signed Cask and Release

Signed/notarized Cask builds and release publishing must not be automated as a
Riela workflow node. They require local signing material, notarization
credentials, GitHub release/tap side effects, and human review. Keep them as
explicit local shell commands run by the release operator inside a kinko shell,
as shown in the credential section above.

### GitHub Actions

GitHub Actions coverage is out of scope for local Riela execution.
`gitleaks.yml` scans secrets on push and pull request using GitHub-provided
execution context, and `linux-amd64-build.yml` builds a Linux amd64 binary on
`main` without local Apple credentials. Riela should not invoke those workflows
locally; local checks should use direct project commands such as `task lint` and
`task build`.

### Rollout and Validation

The rollout is documentation plus one read-only example bundle:

1. Keep this catalog decision as the source of truth for packaging coverage.
2. Add `examples/apple-gateway-packaging-plan/` as a deterministic mock dry-run
   workflow that emits a single JSONL object and can validate without checkout
   access, `task`, Apple app permissions, or credentials.
3. Do not add a `riela/apple-gateway-packaging-*` built-in id.
4. Do not modify `BuiltinWorkflowAddonResolver`, `RielaBuiltinAddonCatalog`,
   add-on execution-contract tests, or the shared Apple Gateway process runner.

Required verification for the implementation step:

```bash
riela workflow validate apple-gateway-packaging-plan --workflow-definition-dir examples
swift build
git status --short
```

No Swift source should change, but `swift build` remains part of implementation
verification because the issue acceptance criteria requires it.
