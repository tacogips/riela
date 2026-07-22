# Expected Results

The commands in `README.md` are deterministic when run with `--dry-run`.

Expected assertions:

- Registered workflow success output reports `scope: "user"`,
  `sourceKind: "workflow"`, `temporary: true`, and `mutable: true`.
- Registered workflows persist across CLI processes, appear in all four list
  formats, validate and run by name, and are hidden by `--exclude-temporary`.
- Duplicate registration requires `--overwrite`; invalid input exits nonzero
  without adding or replacing a catalog entry.
- The optional list query matches workflow/package names case-insensitively.

- File-input run exits with code `0`.
- Inline JSON run exits with code `0`.
- JSON output reports `source.scope` as `temporary`.
- File-input JSON output reports `source.input` as `json-file`.
- Inline JSON output reports `source.input` as `inline-json`.
- Each temporary run writes:
  - `temporary-workflow-payload/input.json`
  - `temporary-workflow-payload/normalized.json`
  - `temporary-workflow-payload/metadata.json`
- `metadata.json` includes a content digest and schema version.
- No project or user workflow installation is required.
