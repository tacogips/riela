# note-link-extract Expected Results

The workflow retrieves a subject note, searches candidate notes, and returns a
reviewable `proposals` array. Each proposal contains `targetNoteId`,
`linkKind`, and `reason`; the UI must still require user confirmation before
creating AI-provenance links.
