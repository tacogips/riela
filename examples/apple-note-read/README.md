# Apple Note Read

This example fetches one Apple Note through the built-in
`riela/apple-note-get` add-on. It invokes the external `apple-gateway`
executable as:

```bash
apple-gateway graphql --query '<query>' --variables '<json>'
```

## Setup

Install or build `apple-gateway` outside this repository, then grant Notes
automation permission:

```bash
apple-gateway permissions request --domain notes
apple-gateway permissions status --json
```

If `apple-gateway` is not on `PATH`, either set `APPLE_GATEWAY_BIN` or add
`binaryPath` to the add-on config in `workflow.json`.

## Run

Validate the bundle:

```bash
swift run riela workflow validate apple-note-read --workflow-definition-dir examples
```

Run with a note id:

```bash
swift run riela workflow run apple-note-read \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"noteId":"NOTE_ID"}}'
```

`materializeBody` is false by default. To download a large body file, set
`materializeBody: true` and use a private runtime directory such as
`tmp/apple-note-read-downloads` through `config.downloadDir` or
`RIELA_APPLE_NOTES_DOWNLOAD_ROOT`.

Deliberate mutation snippets:

```json
{ "name": "riela/apple-note-update-body", "version": "1" }
{ "name": "riela/apple-note-delete", "version": "1" }
{ "name": "riela/apple-note-move", "version": "1" }
```

Those add-ons mutate user data and should be run only from workflows designed
for that purpose.
