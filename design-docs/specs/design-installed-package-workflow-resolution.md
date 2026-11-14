# Installed Package Workflow Resolution

## Overview

Installed workflow packages are local workflow sources. After `riela package
install`, a package-provided workflow must be usable through ordinary
`riela workflow` commands without requiring `--from-registry`.

Packages remain distribution units that may include workflows, skills, scripts,
and metadata. The package wrapper is still important because package-owned
contents should be treated as immutable installed artifacts by default, but the
user-facing workflow command surface should not force users to remember a
separate execution path for already-installed packages.

## Command Semantics

- `riela workflow list --scope <scope>` lists normal workflow catalog entries
  and installed package workflow entries.
- `riela workflow validate <name>`, `inspect <name>`, `status <name>`, and
  `run <name>` resolve installed package workflows as normal local workflows.
- `riela workflow package ...` remains the package management and package
  inspection command surface.
- `--from-registry` is not the installed-package path. It is reserved for
  registry-backed resolution of package/workflow content that is not already
  installed locally.

## Resolution Rules

The resolver preserves existing precedence:

1. direct `--workflow-definition-dir`
2. project/user workflow catalog roots under `.riela/workflows`
3. project/user installed package roots under `.riela/packages`

For package resolution, the command target is the package name. Scoped package
names such as `@scope/name` are valid workflow targets when a matching package
is installed. The resolver loads the package's `riela-package.json`, validates
the manifest and declared workflow bundle, normalizes `workflowDirectory`, and
then resolves the workflow from that package-owned directory.

Package `workflowDirectory` values must stay package-relative and must not
escape the package root after symlink resolution.

## Provenance

Commands that surface workflow metadata include package provenance:

- `sourceKind`: `workflow` or `package`
- `packageName`
- `packageVersion`
- `packageDirectory`
- `mutable`

`sourceKind` is a typed Swift enum with stable string raw values for JSON and
table/text rendering. Package-derived workflows report `mutable: false` so
users and tools know not to edit the installed package contents directly.

## Safety

Normal workflow names continue to use the scoped workflow-name validator.
Installed package workflow targets use the package-name validator because
scoped package names include `/`. Path traversal and absolute package workflow
directories remain rejected during manifest validation and resolver containment
checks.

## Testing

Coverage must prove:

- installed package workflows appear in `workflow list`
- `workflow validate`, `inspect`, and `run` work without `--from-registry`
- scoped packages such as `@scope/scoped-flow` resolve as local workflows
- provenance fields show `sourceKind: package`, package identity, and
  `mutable: false`
- dry-run package commands do not create runtime records even when other tests
  have already run an installed package workflow
