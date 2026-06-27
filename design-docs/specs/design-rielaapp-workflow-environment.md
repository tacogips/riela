# RielaApp Workflow Environment Files

This design records the implemented RielaApp support for workflow and package
environment setup. It covers the Workflows window, package metadata, workflow
env discovery, state persistence, and environment propagation into served
workflows and event-source children.

## Goals

- Let a user choose an arbitrary `.env` or `*.env` file for each RielaApp
  workflow or package-backed workflow.
- Treat selected env files as credential material: RielaApp confirms before
  using a file and never renders env values in the UI.
- Show whether every required environment variable for the selected workflow is
  configured.
- Support package-declared required env metadata and workflow-authored required
  env bindings.
- Pass the selected env file values into the workflow-serving request and any
  daemon event-source child process.

## User Flow

The Workflows window lists enabled and disabled workflow/package candidates.
Each row includes an `Env` status column:

- `No req`: the workflow has no known required environment variables and no
  env file selected.
- `File`: the workflow has no known required environment variables but does
  have an env file selected.
- `Ready`: all known required variables are configured in the selected env file
  or inherited process environment.
- `Missing <n>`: one or more required variables are not configured.

Selecting a row shows detail text that includes the selected env file name, the
missing variable names, or `all required env set`. The `Env File...` action is
enabled for any selected workflow. When no file is selected it opens an
`NSOpenPanel`; when a file is already selected it offers choose, clear, or
cancel. The picker accepts `.env` and `*.env` paths, including hidden `.env`
files. Before saving the selection, RielaApp confirms that the file will be
treated as credential material.

## State Model

The selected file path is stored in
`RielaAppDaemonWorkflowPreference.environmentFilePath`. Preferences are already
profile-scoped and keyed by workflow identity, so env file selection follows
the same profile and workflow boundary as availability and auto-start.

Re-importing a package or workflow preserves the existing preference when the
import replaces an existing profile item. Clearing the env file removes only
`environmentFilePath`; it does not alter availability or auto-start.

## Environment Sources

RielaApp derives required env names from three sources:

- package manifest `environmentVariables` entries where `required` is true;
- workflow `addon.env.<target>.fromEnv` bindings, where `required` defaults to
  true and `required: false` is ignored for readiness;
- required `agentEnvironment.<target>.fromEnv` bindings where `required` is
  true.

The package manifest entry can also carry `description` and `secret` metadata.
That metadata is retained for package-sourced requirements; workflow-authored
requirements currently expose only the env name.

`RielaAppEnvironmentFileStore` parses simple dotenv assignment lines, ignores
invalid env names, merges `ProcessInfo.processInfo.environment`, and lets the
selected file override process values. It reports configured status by checking
for non-empty values without returning values to the UI.

## Runtime Propagation

When RielaApp starts or restarts a daemon workflow, it passes the merged
environment through `WorkflowServeStartRequest.inheritedEnvironment`.
`RielaAppDaemonWorkflowRuntime` retains that inherited environment with the
running workflow so automatic event-source restarts use the same values.

`RielaAppDaemonProcessEventSourceFactory` receives the same inherited
environment for child `riela events serve` processes and overlays telemetry
propagation values. This keeps workflow event sources consistent with the
selected RielaApp env file while preserving OpenTelemetry child-process
attributes.

## Security And Privacy

The UI may display the env file basename and required variable names. It must
not display env values. Credential values are passed only as process
environment to the workflow runtime and event-source child process. Logs should
continue to avoid serializing inherited env values.

The current implementation intentionally does not copy env files into the
RielaApp profile directory. The preference stores a path reference selected by
the user.

## Tests

The implementation is covered by tests for:

- package manifest environment metadata decoding and validation;
- workflow discovery of package and workflow-authored required env variables;
- selected env file parsing and configured/missing status;
- preference persistence of `environmentFilePath`;
- event-source child-process inherited environment propagation; and
- runtime restart preservation of inherited env.
