# Riela Command And RielaApp Package Workflow Ideal Specification

Status: draft for product/design and implementation review

Issue reference: `workflow-input:Add menu-controlled localhost web server (default 19091) with Bun+SolidJS UI to RielaApp`

Feature ID: `command-app-package-workflow-ux`

Workflow mode: `issue-resolution`

## Problem Statement

Riela users can install, import, configure, run, and troubleshoot workflows from both the `riela` command and RielaApp, but the product model is currently fragmented. The command surface has richer package-manager concepts such as registry state, required environment, validation, and update readiness. RielaApp has native workflow and daemon state, plus a planned localhost browser UI, but its list/API contracts do not yet expose enough package/workflow readiness information for a user to decide what is safe to run before clicking.

The product goal is one shared, truthful package/workflow model across command and app surfaces. A user should be able to see whether a workflow is ready, disabled, missing required environment, update-available, invalid, running, stopped, or failed; understand its source and scope; configure environment without exposing secret values; import/update packages from archives and directories; enable or disable app-managed sources without losing preferences; and recover from failures with concrete next actions.

This specification covers both surfaces as first-class experiences. The command is not merely an implementation detail of RielaApp, and RielaApp is not merely a graphical wrapper around the command.

## User Personas And Jobs

### Command user

- Lists installed/discovered packages and workflows from a terminal.
- Installs, imports, validates, packs, updates, enables, disables, and runs workflows.
- Needs scriptable JSON with stable fields, non-zero failures, and actionable stderr/error payloads.
- Needs examples that work offline when possible and clearly say when registry/git/cache access is required.

### App user

- Opens RielaApp to browse workflows, imported packages, daemon instances, and run status.
- Starts/stops the app-local browser server from the status menu and expects menu labels to match actual listener state.
- Needs row-level state badges, primary actions, disabled-action help, environment readiness, logs/status, and safe retry guidance before running anything.
- Needs secret values hidden by default and not leaked into browser APIs, telemetry, screenshots, logs, or errors.

### Package author/operator

- Creates package manifests and workflow metadata that work in both CLI and app.
- Declares required environment names, descriptions, secret flags, dependencies, compatibility, update source, package/workflow IDs, and validation expectations.
- Publishes packages to registry/archive/directory sources and needs import/update results to explain added, updated, skipped, failed, dependency, and validation outcomes.
- Operates across project, user, profile, registry, archive, and directory scopes without ambiguous labels.

## Ideal Cross-Surface Model

### Shared objects

| Concept | Meaning | User-visible fields |
| --- | --- | --- |
| Package | Installable bundle containing one or more workflows and metadata. | `packageId`, name, version, source, scope, install state, update state, validation state, workflow IDs, dependencies. |
| Workflow | Runnable workflow definition, standalone or package-owned. | `workflowId`, name, package owner, source path label, backend hints, tags, readiness, run state, required environment. |
| Source | Where the package/workflow came from. | `sourceType`, `sourceLabel`, `sourceId`, registry/archive/directory/project/user/profile. |
| Scope | Where Riela is allowed to use or persist it. | `project`, `user`, `profile`, `registry`, `archive`, `directory`, `app-bundled`. |
| Instance | App-managed daemon/runtime configuration for a workflow. | active, available, enabled at launch, runtime status, last session, logs/status link. |
| Required environment | Declaration that a workflow/package needs a variable. | name, description, source package/workflow, required/optional, secret flag, configured source, present/missing. |

### Canonical states

| State | Meaning | Primary action | Disabled/hidden behavior |
| --- | --- | --- | --- |
| `ready` | Valid, enabled, required environment present, not currently running. | Run | Update may be secondary if available. |
| `disabled` | User or app preference prevents use, but source is present. | Enable | Run disabled with help explaining disabled source or instance state. |
| `missing-env` | Required environment is absent or unresolved. | Configure environment | Run disabled; secret values hidden. |
| `update-available` | Installed source can be updated. | Update | Run may remain available only if current version is otherwise ready. |
| `invalid` | Manifest/workflow/package validation failed. | Validate or Inspect issue | Run disabled; import may require repair/overwrite confirmation. |
| `source-missing` | Preference/install record exists but source cannot be found. | Reveal source or Remove from profile | Run/update disabled unless provenance can repair. |
| `running` | Workflow/instance/session is active. | Open logs or Stop workflow | Unsafe duplicate run disabled unless workflow supports concurrency. |
| `stopped` | Previously ran or server/instance is off. | Run or Start | Logs/status remain available when history exists. |
| `failed` | Run, serve, import, update, or validation failed. | Retry or Open logs | Error copy includes next safe action and sanitized details. |

### Readiness

Readiness is derived, not hand-authored. It combines validation, enabled/disabled preferences, source availability, required environment presence, dependency state, update compatibility, and runtime state. CLI and app may show surface-specific labels, but they must use the same underlying JSON fields and severity ordering:

1. `invalid`
2. `source-missing`
3. `disabled`
4. `missing-env`
5. `failed`
6. `running`
7. `update-available`
8. `ready` or `stopped`

When multiple states apply, list all `issues[]` and choose `readiness.state` from the highest blocking state. Update availability is non-blocking unless compatibility or validation says otherwise.

### Enabled and disabled behavior

The product vocabulary must separate four concepts:

- Package installation: whether a package exists in a usable package root.
- Source availability: whether a project/user/profile source is included in discovery.
- Instance active state: whether a RielaApp daemon instance is enabled for current use.
- Autostart preference: whether RielaApp starts an instance or web server at launch.

`Enable` and `Disable` in RielaApp apply to app-managed source availability or instance active state, depending on the row type, and the UI must name which one. Re-import/update preserves user preferences for source availability, instance active state, and autostart unless the user explicitly chooses reset/repair.

For archive and directory imports, disabling never deletes files or forgets provenance. A disabled `.rielapkg`, `.zip`, package directory, or workflow directory remains visible as Disabled with its source label, last known version, validation state, and an Enable action. If the underlying directory/archive path is gone, the state becomes Source missing and the primary action changes to Reveal source or Remove from profile. Re-importing the same source keeps the disabled preference unless the result dialog includes and the user chooses Reset preferences.

### Source and scope vocabulary

Use the same labels and JSON values everywhere:

- `app-bundled`: shipped with RielaApp.
- `registry`: installed or updatable from a registry record.
- `archive`: `.rielapkg` or `.zip` imported from a file.
- `directory`: package or workflow directory imported from disk.
- `project`: project-scope package/workflow root.
- `user`: user-scope package/workflow root.
- `profile`: RielaApp profile-managed source.

Absolute paths are not shown by default in the browser. Use stable source labels and a separate reveal action when the native app can safely show a path the user already chose.

## Riela Command Experience

### Commands and flags

The command surface should expose one consistent package/workflow flow:

```text
riela package search [query] --scope project|user|all --output table|json
riela package status [package-or-workflow] --scope project|user|all --output table|json
riela package install <package-ref> --scope project|user --output table|json
riela package import <archive-or-directory> --scope project|user --overwrite --output table|json
riela package update [package-ref] --scope project|user|all --dry-run --output table|json
riela package validate <archive-or-directory-or-package-id> --output table|json
riela package enable <package-or-source-id> --scope project|user|profile --output table|json
riela package disable <package-or-source-id> --scope project|user|profile --output table|json
riela workflow list --scope project|user|profile|all --output table|json
riela workflow inspect <workflow-id> --scope project|user|profile --output json
riela workflow run <workflow-id> --scope project|user|profile --variables <json> --output table|json
riela workflow status <session-or-workflow-id> --output table|json
riela workflow logs <session-id> --tail <n> --output text|json
```

If package-level enable/disable is not implemented in the current CLI, the command must either be added or the app-only semantics must be explicit. A command-review acceptance decision cannot rely on hidden app preferences.

### Output fields

Table output must be scannable; JSON output must be stable:

```json
{
  "items": [
    {
      "packageId": "example",
      "workflowIds": ["example.workflow"],
      "name": "Example",
      "version": "1.2.3",
      "scope": "user",
      "sourceType": "registry",
      "sourceLabel": "tacogips/riela-packages",
      "installState": "installed",
      "readiness": {"state": "missing-env", "blocking": true},
      "update": {"state": "available", "currentVersion": "1.2.3", "latestVersion": "1.3.0"},
      "validation": {"valid": true, "issues": []},
      "requiredEnvironment": [
        {
          "name": "OPENAI_API_KEY",
          "description": "API key used by the model provider.",
          "sourcePackageId": "example",
          "sourceWorkflowId": "example.workflow",
          "required": true,
          "secret": true,
          "configuredSource": "inherited",
          "present": false
        }
      ],
      "actions": {
        "primary": "configure-environment",
        "secondary": ["validate", "update", "inspect"],
        "disabled": [{"action": "run", "reason": "Missing required environment: OPENAI_API_KEY"}],
        "hidden": ["secret-values"]
      }
    }
  ],
  "meta": {"schemaVersion": 1}
}
```

### Status labels

Use these labels in human output: Ready, Disabled, Missing env, Update available, Invalid, Source missing, Running, Stopped, Failed. Machine JSON uses the canonical lowercase states above.

### Errors

Command errors must use non-zero exit status and JSON error envelopes when `--output json` is selected:

```json
{
  "error": {
    "code": "missing-required-environment",
    "message": "OPENAI_API_KEY is required before running example.workflow.",
    "nextAction": "Set OPENAI_API_KEY or configure an environment file, then run validate again.",
    "details": [{"field": "requiredEnvironment[0].name", "value": "OPENAI_API_KEY"}]
  }
}
```

Do not include secret values, request bodies, raw stack traces, or full private paths unless the user explicitly supplied the path in the same command.

Expected command recovery copy:

| Scenario | Exit/status behavior | User-visible message | Next action |
| --- | --- | --- | --- |
| Missing required environment before run | Exit `2`; JSON code `missing-required-environment` | `OPENAI_API_KEY is required before running example.workflow.` | `Set OPENAI_API_KEY or configure an environment file, then run validate again.` |
| Disabled source | Exit `2`; JSON code `source-disabled` | `example is disabled in this scope.` | `Run riela package enable example --scope <scope> or choose another workflow.` |
| Source missing | Exit `2`; JSON code `source-missing` | `The recorded source for example could not be found.` | `Restore the source path, re-import it, or remove the stale record.` |
| Invalid manifest | Exit `1`; JSON code `invalid-manifest` | `example failed package validation.` | `Run riela package validate <source> --output json and fix the listed fields.` |
| Update source unavailable/offline | Exit `1` for update; status stays runnable when otherwise ready | `Update source is unavailable right now.` | `Try again when online or run the current installed version.` |

### Examples

```bash
riela package status --scope all --output table
riela package import ./dist/example.rielapkg --scope user --output json
riela package validate ./example-package --output json
riela package update example --dry-run --output table
riela workflow run example.workflow --variables '{"topic":"demo"}' --output json
riela workflow status <session-id> --output table
```

### Command acceptance criteria

- Given installed, disabled, missing-env, update-available, invalid, source-missing, running, stopped, and failed fixtures, `riela package status --scope all --output table` and `riela workflow list --scope all --output table` show the canonical human labels before any run prompt.
- Given the same fixtures, `--output json` returns `schemaVersion`, `sourceType`, `sourceLabel`, `scope`, `installState`, `readiness`, `update`, `validation`, `requiredEnvironment`, `actions`, and sanitized `issues[]` without secret values or private absolute paths.
- Given `.rielapkg`, `.zip`, package directory, and workflow directory inputs, import/update result JSON reports `added`, `updated`, `skipped`, `failed`, `dependencies`, `validation`, `preferencesPreserved`, and `nextAction` rows.
- Given disabled archive and directory sources, enable/disable either works in CLI with matching app semantics or the CLI explicitly returns a documented app-only error with stable JSON fields.
- Given missing env, disabled source, source missing, invalid manifest, and update-offline cases, commands exit non-zero, return stable error codes, sanitized messages, and actionable `nextAction` values.
- Tests assert table labels, JSON field presence, missing env, secret redaction, update unavailable/offline, invalid manifest, disabled state, source-missing state, and preference preservation.

## RielaApp Experience

### Local web server lifecycle

RielaApp owns an app-local HTTP service that binds only `127.0.0.1`, defaults to `19091`, serves bundled Bun/SolidJS/Tailwind assets from `Resources/Web`, and exposes versioned `/api/v1` JSON backed by in-process app state. It is separate from `RielaServerConfiguration`; the CLI/server default remains `127.0.0.1:8787`.

Menu states must be truthful:

| State | Primary item | Open in Browser | Status copy |
| --- | --- | --- | --- |
| Stopped | Start Web Server | disabled | `Web Server: Off · Configured 127.0.0.1:<port>` |
| Starting | Starting Web Server... | disabled | `Web Server: Starting 127.0.0.1:<port>` |
| Running | Stop Web Server | enabled | `Web Server: On · 127.0.0.1:<actual-port>` |
| Stopping | Stopping Web Server... | disabled | `Web Server: Stopping <actual-address>` |
| Failed | Start Web Server | disabled | `Web Server failed: <safe reason>. <next action>` |

Open in Browser never starts a stopped server. Stop does not claim success until the listener has released the port.

### Workflow/package list

The browser overview must include columns or equivalent responsive fields:

- Name
- Package/workflow ID
- State badge
- Scope
- Source type and label
- Version
- Workflow IDs or instance count
- Required environment summary
- Update state
- Validation state
- Run state / last run
- Primary action
- Secondary actions

Every row exposes a single primary action derived from state: Run, Configure environment, Update, Enable, Validate, Open logs, Retry, or Start. Unsafe actions are hidden or disabled with visible help text. Examples:

- Missing env: primary Configure environment; Run disabled with missing variable names.
- Disabled: primary Enable; Run disabled with source/instance disabled explanation.
- Invalid: primary Validate/Inspect issue; Run hidden or disabled.
- Running: primary Open logs or Stop workflow; duplicate Run disabled unless concurrency is supported.
- Update available: primary Update if update is the user's likely next job; Run remains visible only when current package is ready.

### Required environment UI

Environment configuration shows a table:

- Variable name
- Description
- Source package/workflow
- Required/optional
- Secret/non-secret
- Configured source: `.env`, inline, inherited, missing
- Readiness: present or missing

Secret values are never displayed in browser lists, dialogs, API responses, telemetry, screenshots, logs, or error payloads. For non-secret inline values, the safer default is still to show presence and source, with explicit reveal/edit controls in native UI only if product approves it.

Readiness is boolean and name-based: `present: true` means a non-empty value resolves from an approved source for the current run context; `present: false` means no approved value resolves. Browser API responses may return the variable name, description, `secret`, `required`, `configuredSource`, and `present`, but never the value, a hash of the value, length, prefix, suffix, or examples derived from the value.

### Import and update dialogs

RielaApp supports import/update of:

- `.rielapkg` archive
- `.zip` package archive
- package directory
- workflow directory
- registry install/update when available
- project/user/profile sources

Result dialogs show added, updated, skipped, failed, dependency, and validation rows. Each row includes source type, source label, package/workflow IDs, target scope, previous version, new version, preserved preferences, and next action. Invalid imports can be validated before import and cannot be silently installed without a repair/overwrite confirmation.

Dialog feedback must tie each result to the action the user took:

- Import archive/directory: `Imported <name>` or `Import failed for <source label>`, followed by row-level added/updated/skipped/failed counts and a primary next action such as Run, Configure environment, Validate, or Keep disabled.
- Update package: `Updated <name> from <old> to <new>`, `Already current`, or `Update failed`, with rollback/failure summary and whether disabled/autostart preferences were preserved.
- Validate before import/run: `Validation passed` or `Validation failed`, with field-level issues and no install/run side effects on failure.

### Enable/disable confirmations

Enable/disable controls must name the affected layer:

- Enable source in profile
- Disable source in profile
- Enable instance
- Disable instance
- Enable autostart
- Disable autostart

Confirmations preserve user preferences across re-import/update. If a package is invalid or missing environment, Enable may be allowed only when it means "include in discovery"; Run remains disabled until readiness is resolved.

Confirmation copy must be explicit:

- `Disable source in profile? The package stays installed, but workflows from this source will not appear as runnable until re-enabled.`
- `Enable source in profile? Workflows will appear, but invalid packages or missing environment still cannot run.`
- `Disable instance? The workflow source remains installed, but this app instance will not run until re-enabled.`
- `Enable autostart? RielaApp will start this item when the app opens.`

### API routes

The existing localhost transport contract remains useful and should be retained where applicable:

| Method and path | Contract |
| --- | --- |
| `GET /healthz`, `GET /overview`, `POST /graphql`, `POST /note/register` | Existing deterministic routes through the route adapter. |
| `GET /api/v1/bootstrap` | Server state, bound URL, active profile label, capabilities, CSRF token. |
| `GET /api/v1/workflows` | Package/workflow list with readiness, scope/source, required environment, update, validation, actions, and run state. |
| `GET /api/v1/workflows/:sourceId` | Inspect package/workflow details, metadata, required environment, issues, editable referenced files. |
| `POST /api/v1/packages/import` | Import archive/directory with validation and result summary. |
| `POST /api/v1/packages/:packageId/update` | Update package with dependency/validation/preference-preservation result. |
| `PATCH /api/v1/sources/:sourceId/availability` | Enable/disable source availability with expected revision. |
| `PATCH /api/v1/instances/:identity/configuration` | Existing instance configuration patch, revision-checked. |
| `GET /api/v1/instances/:identity/sessions` | Session summaries. |
| `GET /api/v1/instances/:identity/sessions/:sessionId` | Timeline/log diagnostics. |
| `POST /api/v1/workflows/:workflowId/run` | Start workflow only when readiness allows it. |
| `POST /api/v1/sessions/:sessionId/stop` | Stop running workflow/session when supported. |
| `GET/PATCH /api/v1/settings/web-server` | Persist enabled-at-launch/configured-port and expose actual lifecycle/bound-port. |

Mutations require same-origin, host validation, CSRF token, revision checks, atomic persistence, and shared native validation/restart behavior. Errors must be non-2xx, sanitized, and include `nextAction` when recovery is possible.

API/browser error copy uses the same codes as CLI where the cause is shared. HTTP `409` means stale revision or port collision, `422` means validation/readiness prevents the action, `404` means source/session not found, and `500` is reserved for unexpected sanitized failures. Browser dialogs show the safe message and next action only; detailed diagnostics are available through bounded logs.

### RielaApp acceptance criteria

- Given fixtures for ready, disabled, missing-env, update-available, invalid, source-missing, running, stopped, and failed rows, the browser shows the canonical badge, matching primary action, and disabled-action help before any run starts.
- Given required secret and non-secret environment fixtures, the browser and `/api/v1/workflows` show names, descriptions, source package/workflow, secret flag, configured source, and present/missing readiness without value, hash, length, prefix, suffix, or derived examples.
- Given `.rielapkg`, `.zip`, package directory, workflow directory, and registry update inputs, import/update dialogs show added/updated/skipped/failed/dependency/validation rows, preserved preferences, rollback/failure summaries, and a next action.
- Given disabled app-managed archive and directory sources, re-import/update preserves disabled/source availability, instance active state, and autostart until the user chooses Reset preferences.
- Given source, instance, and autostart controls, confirmation copy names the exact affected layer and Run remains blocked while validation or required environment is unresolved.
- Given web server start/stop/open actions, menu copy reflects actual lifecycle, `127.0.0.1:<bound-port>`, port collision recovery, and released-port stop behavior.
- Given API failures, browser dialogs and JSON responses use non-2xx status, stable error code, sanitized message, and `nextAction`; logs contain bounded diagnostics only.
- Given browser changes, native Swift Instances, Notes, Note Settings, Viewer, prompt/profile, and assistant windows still open and behave as before.

## Metadata Contract

### Manifest fields

Package manifests should provide:

```json
{
  "schemaVersion": 1,
  "packageId": "example",
  "name": "Example",
  "version": "1.2.3",
  "description": "Short user-facing description.",
  "workflows": [
    {
      "workflowId": "example.workflow",
      "name": "Example Workflow",
      "tags": ["demo"],
      "backendHints": ["codex"],
      "requiredEnvironment": ["OPENAI_API_KEY"]
    }
  ],
  "requiredEnvironment": [
    {
      "name": "OPENAI_API_KEY",
      "description": "API key used by the model provider.",
      "required": true,
      "secret": true,
      "appliesTo": ["example.workflow"]
    }
  ],
  "dependencies": [{"packageId": "shared-tools", "versionRequirement": ">=1.0.0"}],
  "compatibility": {"riela": ">=0.0.0"},
  "update": {"sourceType": "registry", "sourceRef": "example"},
  "validation": {"strict": true}
}
```

### Runtime/readiness fields

All CLI/app list APIs should project:

- `installState`: `not-installed`, `installed`, `imported`, `app-bundled`, `source-missing`, `disabled`.
- `readiness.state`: canonical state, blocking flag, issue count.
- `validation.valid`: boolean plus typed `issues[]`.
- `update.state`: `unknown`, `unavailable`, `current`, `available`, `failed`.
- `requiredEnvironment[]`: name, description, source package/workflow, required, secret, configured source, present.
- `actions`: primary, secondary, disabled with reasons, hidden with reasons.
- `provenance`: source type, source label, source ID, scope, cache/registry revision if available.
- `runtime`: running/stopped/failed, last session, last status time, bounded diagnostics.

### Compatibility assumptions

- Older manifests without rich environment descriptions remain valid but produce fallback descriptions and compatibility warnings.
- Unknown metadata fields are preserved where package tooling rewrites manifests.
- App/browser APIs do not expose secret values even if older manifests lack `secret`; variable names matching common secret patterns should default to secret until metadata is explicit.
- Update availability may be `unknown` offline; this must not block running an otherwise ready package.
- Rich app validation should reuse shared package support logic instead of duplicating CLI rules.

### Risks and migration assumptions

- Existing package/workflow records may not have stable source IDs; migration must create deterministic IDs without changing user-visible labels.
- Some current CLI commands may not own enable/disable; until implemented, command help and JSON must say app/profile-only instead of pretending parity exists.
- Offline update checks can be stale; UI must label update state `unknown` rather than implying current or failed without evidence.
- Directory sources can move or be deleted outside RielaApp; Source missing recovery must be treated as normal user flow, not an internal error.
- Browser UI is a companion surface; native Swift UI remains the source of truth for app-local settings that the browser cannot safely mutate.

## Review And Verification Plan

### CLI tests

- `riela package status --output json` includes readiness, source/scope, update, validation, actions, and required environment fields.
- `riela workflow list --output table` shows canonical labels and enough columns to decide before running.
- Import/update tests cover `.rielapkg`, `.zip`, package directory, workflow directory, dependency success/failure, validation failure, overwrite, and preference preservation.
- Error tests cover missing env, source missing, invalid manifest, update unavailable/offline, conflicting versions, and sanitized secret handling.
- Enable/disable tests exist if CLI owns those commands; otherwise docs/tests assert app-only semantics explicitly.

### App support tests

- `DaemonWorkflowSupport` projects app/user/project/profile sources with package metadata, validation issues, update source, and scope.
- `EntryPoint+Environment` readiness computation redacts values and includes descriptions/source metadata.
- `RielaAppWebAPI` returns package/workflow list DTOs with package states, env readiness, import/update summaries, enable/disable revisions, and sanitized errors.
- Preference policy tests prove re-import/update preserves source availability, instance active state, and autostart.
- Web-server settings tests keep `19091` independent of `RielaServerConfiguration` default `8787`.

### UI QA

- Browser smoke checks verify badges/actions, disabled-action help, filters, empty states, env dialogs with redaction, import/update result dialogs, enable/disable confirmations, logs/status polling, and keyboard-accessible troubleshooting actions.
- Native UI preservation checks open Instances, workflow viewer, prompts, profile selection, Notes, Note Settings, and menu status after browser changes.
- Lifecycle checks start/stop the localhost server, verify `127.0.0.1:<bound-port>`, confirm port collision copy, stop release, and Open in Browser enablement.

### Docs/examples

- CLI help includes the canonical state labels and JSON examples.
- App docs explain scope/source vocabulary and the difference between package installation, source availability, instance active state, and autostart.
- Package author docs describe required environment metadata, secret defaults, update provenance, and compatibility behavior.

### Regression checks

- No shipped browser fixture contains secrets, instance IDs, request bodies, private paths, or raw telemetry.
- `git diff --check`.
- Focused Swift tests for changed support/API behavior.
- RielaApp build and browser smoke when app/browser code changes.
- SwiftLint after Swift edits.

## Prioritized Backlog

### Must

- Add a shared package/workflow list contract with canonical states, action model, source/scope fields, required environment metadata, validation, update, and runtime status.
- Extend `RielaAppWebAPI` and support projections so the browser list can distinguish ready, disabled, missing-env, update-available, invalid/error, running, and stopped.
- Implement required environment readiness rows with secret redaction across CLI JSON, app API, and browser UI.
- Define and test enable/disable semantics for app-managed rielapkg and directory sources, preserving user preferences across re-import/update.
- Add import/update result models for `.rielapkg`, `.zip`, package directories, workflow directories, dependency results, validation issues, and rollback/failure summaries.
- Make API/CLI errors sanitized, typed, non-successful, and actionable with `nextAction`.

### Should

- Align CLI `package status/search/update` JSON with the app list contract.
- Add workflow serving controls and session/log inspection to the browser with bounded diagnostics and safe retry copy.
- Add visual/accessibility requirements for badges, filters, empty states, dialogs, disabled-control help, and keyboard operation.
- Share validation/update/readiness support modules to avoid drift between CLI and app.
- Add telemetry/status rules that record route templates and lifecycle/import/update outcomes only, without secrets, request bodies, instance IDs, or private paths.

### Could

- Add native reveal-source actions that show paths only after user intent.
- Add pagination/truncation UX for very large session timelines.
- Add offline registry cache diagnostics that distinguish no registry, stale cache, and update source unavailable.
- Add package author lint suggestions for missing descriptions or missing `secret` flags.

## Open Questions And Non-Goals

### Open questions

- Should `riela package enable/disable` exist for project/user scopes, or should enable/disable remain app/profile-only for now?
- Is source availability or instance active state the default meaning of Enable in the browser list when a row represents both a package and an app instance?
- Can non-secret inline environment values ever be revealed in the browser, or should all values remain hidden there?
- What is the authoritative update source when a package was imported from a local archive and also matches a registry package ID?
- Which workflow run modes permit concurrent duplicate runs from the browser?

### Non-goals

- Remote web access, TLS termination, multi-user authentication, or exposing RielaApp beyond loopback.
- Replacing the native RielaApp windows.
- Treating the CLI `serve` endpoint or `RielaServerConfiguration` default port as the app browser server.
- Showing secret values in browser APIs or logs.
- Implementing arbitrary filesystem editing from the browser.
- Guaranteeing registry/update availability while offline.
