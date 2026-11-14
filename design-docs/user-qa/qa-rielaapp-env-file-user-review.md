# RielaApp Env File Feature Review

## Current User Journey

1. A user imports or exposes a workflow/package in RielaApp.
2. The Workflows window shows whether the workflow/package is enabled,
   disabled, auto-started, running, and whether required env is ready.
3. The user selects a workflow and clicks `Env File...`.
4. RielaApp asks the user to choose a `.env` or `*.env` file and confirms that
   the file is credential material before saving the path.
5. The selected workflow detail shows the env file name and missing required
   variables, without displaying values.
6. When the workflow starts, RielaApp passes the selected env file values to the
   workflow runtime and daemon event-source child process.

## What Works Well

- The model is workflow-specific and profile-specific, matching the way users
  think about different bots, gateways, and package imports.
- Required env readiness is visible before start, reducing trial-and-error.
- Credential values are not rendered in UI.
- Package manifests can describe runtime prerequisites, which lets packaged
  workflows become more self-describing.
- Workflow-authored `addon.env` and `agentEnvironment` bindings also contribute
  to readiness, so plain workflow directories benefit even without package
  metadata.

## Gaps From A User Perspective

- The app tells users what is missing, but not where each requirement came
  from: package metadata, add-on binding, or agent binding.
- There is no inline help for creating a `.env` template with the required
  names.
- Readiness is advisory; start is not blocked when required env is missing.
- The CLI and RielaApp do not yet share a single command for explaining env
  requirements.
- Optional env vars are not surfaced, so users may miss useful configuration
  knobs.
- A selected env file is path-based; users can move or delete the file without
  an immediate stale-path warning until readiness is refreshed.

## Ideal Specification

### Manifest And Workflow Contracts

- Package manifests should support `environmentVariables` with `name`,
  `description`, `required`, `secret`, `defaultHint`, `docsURL`, and
  `group`. Groups should express one-of credential choices such as Google ADC:
  `GOOGLE_APPLICATION_CREDENTIALS` or `GOOGLE_APPLICATION_CREDENTIALS_JSON`.
- Workflow inspection should expose a normalized env-requirements contract that
  merges package metadata, `addon.env`, `agentEnvironment`, event-source token
  requirements, and workflow-declared optional settings.
- Each requirement should carry provenance so UI and CLI can say why the value
  is needed.

### RielaApp UX

- The Workflows window should show a compact readiness state: Ready, Missing,
  Optional available, File selected, or File missing.
- The detail pane should include a grouped checklist of required and optional
  variables with provenance and descriptions, never values.
- `Env File...` should offer: choose file, clear file, reveal file in Finder,
  generate template, and copy missing names.
- Starting a workflow with missing required env should prompt with explicit
  choices: cancel, choose env file, or start anyway.
- If a selected env file disappears, readiness should show stale file state.

### CLI And Harness

- `riela workflow env inspect <workflow>` should print the same normalized
  requirement contract that RielaApp uses.
- `riela workflow env template <workflow>` should generate a `.env.example`
  with comments and required names.
- Workflow tests should be able to declare env fixtures so package maintainers
  can verify that missing-env diagnostics are clear.
- Runtime session metadata should record env readiness names and provenance, not
  values, so failed harness runs explain configuration problems without leaking
  credentials.

### Loop Engineering Fit

A loop-engineering harness should make setup state observable before the loop
starts. Env readiness is not just app convenience; it is part of the workflow
contract. The ideal harness treats environment prerequisites like input and
output schemas: discoverable, testable, explainable, and safe to report.

## Prioritized Follow-up Backlog

1. Add normalized env requirement inspection shared by CLI and RielaApp.
2. Add `.env.example` generation from workflow/package requirements.
3. Add provenance and grouped one-of credentials to package metadata.
4. Add stale-file detection and a readiness refresh action in RielaApp.
5. Add start-time warning when required env is missing.
6. Surface optional env settings with descriptions.
7. Add event-source-specific env requirement extraction.

## Non-goals

- RielaApp should not store credential values in its profile state.
- RielaApp should not render env values in tables, detail panes, telemetry, or
  logs.
- Package metadata should not try to validate the semantic correctness of a
  token; it should only describe presence, grouping, and safe setup guidance.
