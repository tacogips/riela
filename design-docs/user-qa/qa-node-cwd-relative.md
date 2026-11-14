# QA: explicit relative command/container `workingDirectory` and bundle compatibility

Status: pending user decision. Recorded 2026-11-11 in the opus-terra run for
fix/node-cwd-relative (findings NCR-D1 and NCR-D2).

## Context

The accepted request is that a relative node, command or container
`workingDirectory` resolves against the run workspace root (`--working-dir`).
The full rule is in `design-docs/specs/design-workflow-json.md`, section
"`workingDirectory` resolution".

Today, `WorkflowRegistryBundleLoader.absolutizedStdioPaths` rewrites an
explicit relative `command.workingDirectory` / `container.workingDirectory`
to the bundle directory when the bundle loads. The exceptions are values that
start with `/` or `./`. Meeting the request therefore means the loader must
stop rewriting run directories. It keeps bundle-relative resolution for
`command.executable`.

## Verified impact

Four shipped example command nodes set `command.workingDirectory: "scripts"`:

- `examples/node-combinations-showcase/nodes/node-command-worker.json`
- `examples/monja-typescript-sdk/nodes/node-monja-command.json`
- `examples/apple-gateway-packaging-plan/nodes/node-packaging-plan.json`
- `examples/first-four-arithmetic-pipeline/workflows/divide/nodes/node-divide-worker.json`

None of their scripts depend on the working directory. `mock-command.sh`,
`divide.sh` and `mock-task-jsonl.sh` use no relative paths, and
`run-installed-command.sh` locates itself through `$0`.

Third-party or user bundles whose scripts assume a bundle-relative run
directory would change behavior. Their spawn may fail if
`<working-dir>/<rel>` does not exist.

Remote (placed) steps are not affected by either option. They keep today's
loader output and worker mapping. Only local dispatch switches to the
recorded `authoredWorkingDirectory` (see the design section).

## Options

A. Apply the request as written. This is the design default.

- Local dispatch anchors explicit relative
  `command.workingDirectory` / `container.workingDirectory` values to
  `--working-dir`. The loader keeps the bundle-absolute value for remote
  steps and records the authored value.
- Delete `"workingDirectory": "scripts"` from the four examples.
- Release notes tell bundle authors to use an absolute path or to rely on
  `scriptPath` for asset location.

B. Keep bundle-relative explicit run directories as an exception.

- Only node-level and inherited directories anchor to the workspace root.
- This narrows the accepted criterion "a command node with a relative
  workingDirectory runs in <working-dir>/<rel>". It requires an explicit
  amendment of the workflow scope before it can be accepted.

## Recommendation

Option A. It matches the request and the distributed-worker semantics, and
the shipped examples migrate with no change in behavior.

## Decision needed

- Confirm A, or approve the scope amendment for B.
- Until a decision is recorded here, implementation follows A. If the loader
  and example edits cannot be authorized, the run reports a scope blocker.
  It does not weaken acceptance.
