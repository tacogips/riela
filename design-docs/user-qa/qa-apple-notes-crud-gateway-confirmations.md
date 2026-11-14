# Apple Notes CRUD Gateway Confirmations

## Question

Before implementation locks the Apple Notes CRUD adapter contract, confirm the
remaining upstream `apple-gateway` behaviors for body download output and
GraphQL error preservation.

## Context

The `riela/apple-note-get` design materializes large note bodies by invoking:

```bash
apple-gateway file download --key <download-key> --output-dir <root>
```

The implementation plan assumes a JSON stdout envelope that can map each
`downloadKey` to a `localPath`. It also requires GraphQL error envelopes for
locked notes and permission-denied cases to preserve upstream
`errors[].message` and any `errors[].extensions.code` values, including
`NOTE_LOCKED`, so Riela can expose provider errors without flattening useful
diagnostics.

## Confirmations Needed

1. Capture the exact stdout envelope emitted by `apple-gateway file download`
   for a successful single `bodyFile.downloadKey` download.
2. Confirm whether locked note errors expose `NOTE_LOCKED` in
   `errors[].extensions.code`, `errors[].message`, or both.
3. Confirm the permission-denied GraphQL error shape, including whether an
   extension code is present and which message text must be preserved.

## Default Until Answered

Implement the parser tolerantly for the file download envelope while requiring a
clear `downloadKey` to local-path mapping. Preserve both GraphQL
`errors[].message` and `errors[].extensions` in provider-error details instead
of reducing them to a single generic message.

## Impact

These confirmations affect fake gateway fixtures, adapter output parsing, and
the provider-error contract for `riela/apple-note-get`,
`riela/apple-note-update-body`, `riela/apple-note-delete`, and any other Notes
operation that can surface locked-note or permission-denied failures.
