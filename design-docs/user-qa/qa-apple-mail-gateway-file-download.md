# Apple Mail Gateway File Download Confirmation

## Question

Before implementation locks the `riela/apple-mail-message` materialization
contract, confirm the exact upstream behavior of:

```bash
apple-gateway file download --key <download-key>
```

## Context

`riela/apple-mail-message` reads Mail message metadata through
`apple-gateway graphql` and may materialize selected body or attachment
descriptors into a Riela-controlled download root. The design assumes Riela
invokes the fixed file-download subcommand with separate process arguments,
captures downloaded bytes, sanitizes gateway filenames as metadata, and writes
the final file path itself under the validated root.

The Notes CRUD design has a related confirmation in
`design-docs/user-qa/qa-apple-notes-crud-gateway-confirmations.md`, but Mail
needs its own confirmation because Mail descriptors can include body text, body
HTML, raw source, and attachments.

## Confirmations Needed

1. Confirm whether `apple-gateway file download --key <download-key>` emits raw
   file bytes to stdout for a single key.
2. If stdout is not the production contract, confirm the exact explicit-output
   arguments required by the gateway.
3. Confirm whether the gateway emits any JSON envelope or metadata for download
   failures, including Full Disk Access denial.
4. Confirm whether Mail attachment filenames or MIME metadata are returned only
   by GraphQL descriptors, or can also be returned by the download command.

## Default Until Answered

Implement `riela/apple-mail-message` and its fake-executable tests as a raw
stdout-byte contract for `file download --key`. If the real gateway requires an
explicit output directory, pass only a Riela-chosen, validated destination and
continue treating gateway filenames as metadata that cannot choose the final
local path.

## Impact

This confirmation affects `riela/apple-mail-message` download parsing,
fake-executable fixtures, provider-error details for file-download failures, and
the stability of local paths returned in `appleMail.materialized[]`.

## Implementation Status

The initial Riela implementation follows the default raw-stdout-byte contract
for fake-executable tests:

```bash
apple-gateway file download --key <download-key>
```

Riela chooses and validates the download root, sanitizes the final leaf
filename, writes stdout bytes itself, and returns the resulting local path. If
the production gateway later requires `--output-dir` or another explicit output
argument, keep the same Riela-controlled destination rule and update this note,
the catalog docs, and fake fixtures together.
