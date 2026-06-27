# Riela Package Archive

## Overview

Riela package archives make workflow packages installable as a single file
without replacing the existing unpacked package directory model. A `.rielapkg`
file is a ZIP container whose extracted root is the same package directory that
`riela package install --source <package-dir>` already accepts.

The archive feature is intentionally a source transport layer:

- unpacked package directories remain the canonical install format
- `.rielapkg` and `.zip` archives are materialized to a temporary directory
  before manifest loading, validation, installation, or execution
- after materialization, existing `riela-package.json` validation and workflow
  resolution rules are reused

## Archive Layout

An archive may contain package files directly at its root:

```text
riela-package.json
workflow.json
nodes/
prompts/
skills/
addons/
```

It may also contain exactly one top-level directory that contains
`riela-package.json`. Archives with sibling entries beside that top-level package
directory are rejected; package content must either live directly at the archive
root or under that single package directory. In both accepted layouts,
`riela-package.json` is the package manifest. For workflow packages,
`workflowDirectory` points to the workflow bundle and defaults to `.` when
omitted.

## CLI Behavior

The package command supports both unpacked directories and archives:

```bash
riela package pack <package-dir> --destination <name>.rielapkg
riela package validate <package-dir-or-archive>
riela package install <package-dir-or-archive>
riela package install --source <package-dir-or-archive>
riela package run <package-name-or-archive>
```

`pack` accepts `.rielapkg` and `.zip` destinations. `validate`, `install`, and
`run` materialize archives under a command-owned temporary root before loading
the manifest. `install` uses the manifest package name when the source is an
unpacked path or archive; a target package id is used only when resolving an
installed or registry package by name. This avoids treating
`riela package install <other-name> --source ./pkg.rielapkg` as a package rename
operation.

## RielaApp Behavior

RielaApp profiles have separate managed roots:

```text
~/.riela/rielaapp/profiles/<profile>/workflows/
~/.riela/rielaapp/profiles/<profile>/packages/
```

RielaApp also keeps a profile-local daemon workflow state file at:

```text
~/.riela/rielaapp/profiles/<profile>/daemon-workflows.json
```

That state is app-local policy, not package or workflow source metadata. Each
candidate has an `available` flag and an `active` flag:

- `available: true` means the workflow is enabled in the current RielaApp
  profile and may be started by the app.
- `available: false` means the workflow stays installed and discoverable, but
  the app must not start it and must stop any app-owned runtime for it when the
  user disables it.
- `active` records whether the enabled workflow should currently be running in
  the app profile. A disabled workflow is never startable from RielaApp even if
  stale state contains `active: true`.

The profile-local `available` setting affects only RielaApp daemon workflow
management. It does not rewrite workflow files, package manifests, checkout
records, event-source contracts, or `riela serve` behavior.

Adding a workflow/package from the RielaApp workflow window accepts:

- an unpacked workflow directory containing `workflow.json`
- an unpacked package directory containing `riela-package.json`
- a `.rielapkg` or `.zip` package archive

Imported packages are expanded into the active profile package root. Startup
discovery, refresh/read, and execution discover those managed package
directories and run their workflow bundles through the same daemon workflow
runtime as project and user packages.

RielaApp package import performs the same package-tree and manifest validation
as the command path after materialization. Invalid package metadata, unsafe
`workflowDirectory` values, missing workflow bundles, loop-promotion artifact
gaps, symlinks, and non-regular filesystem entries are rejected before content
is copied into the profile package root.

The workflow window separates `Enabled Workflows` from `Disabled Workflows`.
Enable moves a discovered workflow into the enabled set and starts it for the
profile. Disable moves it into the disabled set, clears active state, and stops
the app-owned serving controller for that workflow. Removing an app-managed
workflow or package deletes only content contained by the active profile's
managed roots; project/user workflows outside those roots are not deleted.
The add/import and enable/disable/start/stop/remove user actions are implemented
in the RielaApp entry point and daemon workflow window controller, while the
path, profile, validation, and discovery rules live in RielaAppSupport.

## Safety

Archive extraction is handled by `WorkflowPackageArchiveManager`. It rejects
unsupported extensions, requires `riela-package.json`, and validates archive
entry paths before any extractor writes files. Preflight rejects absolute paths,
Windows absolute paths, `..` traversal, entries whose destination would escape
the extraction root, and non-file/non-directory ZIP entry types such as symlinks
or device nodes when the archive metadata exposes them. After extraction it
performs a second package-tree validation that rejects symlinks and non-regular
filesystem entries before install or App import. Extraction happens under a
temporary directory before the package is copied into the final package root.
CLI archive materialization uses `.riela/tmp/rielapkg/<uuid>` below the command
working directory; RielaApp archive materialization uses a profile-local
temporary package root. Temporary materializations are removed after
validation, install, import, or package execution returns, and they are also
removed when archive materialization fails.
