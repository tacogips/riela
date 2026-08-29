# Apple Note Create

This example creates a new Apple Note through the built-in
`riela/apple-note-create` add-on. It invokes the external `apple-gateway`
executable as:

```bash
apple-gateway graphql --query '<mutation>' --variables '<json>'
```

Creating a note adds user data. It does not delete, move, or overwrite existing
notes.

## Setup

Install or build `apple-gateway` outside this repository, then grant Notes
automation permission:

```bash
apple-gateway permissions request --domain notes
apple-gateway permissions status --json
```

The `apple-gateway` code is linked into `riela`; there is no executable to
install, no `APPLE_GATEWAY_BIN`, and no `binaryPath` add-on config. macOS
attaches Apple permission grants to the executable that asks, so grants given
to a standalone `apple-gateway` do not carry over — approve `riela` once from
an interactive run before using this from a daemon.

## Run

Validate the bundle:

```bash
swift run riela workflow validate apple-note-create --workflow-definition-dir examples
```

Run with title and body input:

```bash
swift run riela workflow run apple-note-create \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"title":"Riela note","bodyText":"Created from a workflow."}}'
```

Deliberate mutation snippets:

```json
{ "name": "riela/apple-note-update-body", "version": "1" }
{ "name": "riela/apple-note-delete", "version": "1" }
{ "name": "riela/apple-note-move", "version": "1" }
```

Those add-ons mutate user data and should be run only from workflows designed
for that purpose.
