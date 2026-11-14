# Riela

Riela is the Swift-native workflow runtime behind the `riela` CLI. The runtime
core lives in `Sources/RielaCore`, the command surface in `Sources/RielaCLI`,
the Work Runtime in `Sources/RielaWork`, the mutable workflow registry in
`Sources/RielaWorkflowRegistry`, and the control plane in `Sources/RielaServer`
and `Sources/RielaGraphQL`. Design documents are under `design-docs/specs/`,
implementation plans under `impl-plans/`, and example workflow bundles under
`examples/`.

Keep runtime behavior deterministic, portable, and evidence-driven: runtime
records (session ids, step execution ids, publication, resume and rerun
lineage) are owned by the runtime store, never by workers or adapters. Prefer
mock-scenario workflow runs and focused `swift test --filter` suites to
verify changes; the full suite is large. On Apple Silicon run `swift build`,
`swift test`, and `swiftlint` from an arm64 shell.

## Temporary and scratch files

Write every throwaway artifact under the repository-root `tmp/` directory, which is gitignored. This includes ad-hoc wrapper scripts, command/verification logs, evidence output, scratch inputs, and intermediate JSON. Prefer a per-task subfolder such as `tmp/<task-name>/` and remove it when the task is done.

Do not create temporary files at the repository root or inside `scripts/`. The repository root must stay free of scratch `.sh`/`.txt` wrappers, and `scripts/` is reserved for committed, reusable tooling only. Never `git add` scratch artifacts; if a temporary file must live outside `tmp/`, add an explicit ignore rule instead of committing it.
