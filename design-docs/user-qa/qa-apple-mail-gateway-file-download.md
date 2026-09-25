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

## Confirmed Contract (2026-09-21)

The installed CLI, its checked-in command specification, implementation, smoke
tests, and focused file-store tests agree on the contract:

- `file download` materializes each requested file under the configured cache
  root or an explicit `--output-dir`.
- stdout is a JSON success envelope containing `data.files[]`; each entry has
  `downloadKey`, `domain`, `kind`, and `path`. It is not raw file bytes.
- failures use the shared JSON error envelope, including
  `INVALID_DOWNLOAD_KEY` and `FILE_OPERATION_FAILED`.
- filename and MIME metadata remain available from the GraphQL descriptor; the
  download manifest provides the materialized path and file kind.

Riela now supplies its validated private runtime root with `--output-dir`,
parses the exact envelope, validates the returned regular path is contained,
checks the actual on-disk size, and publishes under its own sanitized filename.

## Impact

This confirmation affects `riela/apple-mail-message` download parsing,
fake-executable fixtures, provider-error details for file-download failures, and
the stability of local paths returned in `appleMail.materialized[]`.

## Implementation Status

The corrected Riela implementation follows the confirmed manifest contract:

```bash
apple-gateway file download --key <download-key> --output-dir <validated-root>
```

Riela chooses and validates the download root, validates the manifest mapping,
sanitizes the final leaf filename, enforces the cap against the materialized
file, and returns the resulting local path.
