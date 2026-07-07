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
5. run `apple-gateway graphql --query <fixed-document> --variables <json>` with
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

