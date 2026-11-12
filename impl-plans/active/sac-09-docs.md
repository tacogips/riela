# sac-09-docs: document local mode, mode precedence, channel and codes

- planId: `sac-09-docs`
- wave: 1, dependsOn: none
- design: `design-docs/specs/design-serverless-app-control.md` §3.1, §3.2, §3.4, §3.5, §3.7, §3.10, §3.11, §4
- writePaths:
  - `docs/app-instance-control.md`
  - `README.md` (the CLI section paragraph only)
  - `impl-plans/progress/sac-09-docs.md`
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-09/`

## Intent and context

Users and agents need to know four things:

- with no `--server`, the CLI controls the local RielaApp through an
  owner-only Unix socket and local disk reads;
- `--server <url>` keeps HTTP;
- which commands need a running App;
- what the new error codes mean.

The design-doc pointer was already added in Step 2
(`design-instance-reload-run-cli.md` D1). Do not edit design docs.

## Non-goals

- No source or test changes.
- No skill or other docs edits.
- Do not document an env var or an in-process run flag; neither exists.

## Changes

### `docs/app-instance-control.md`

**Replace the "Prerequisites" and "Discovery and identity" sections** with a
"Modes" section and an updated discovery section.

- Precedence:
  - `--server <url>` → HTTP (local or remote; today's CSRF and profile flow);
  - otherwise local mode;
  - no env var; there is never an implicit HTTP fallback;
  - non-macOS requires `--server` (`app_server_required`).
- Discovery is unchanged: `RIELA_APP_ROOT` or `~/.riela/rielaapp`; profile
  from `--profile` or `active-profile.json`; the session store at
  `~/.riela/profiles/<profile>/sessions`. No new location options.
- The channel:
  - `<app-root>/run/` (0700), `run/control.sock` (0600), `run/app.lock`;
  - same-user peer check;
  - request limit 576 KiB, response limit 1 MiB, 30 s timeout;
  - idempotent request ids;
  - requests and responses are never written to disk;
  - environment status returns names and readiness only.
- A partition table, copied from design §3.2: which commands go through the
  channel, which are local reads, and the `app_not_running` cases.
- Local reload without an App:
  - validate, definition import and relink under `app.lock`;
  - no respawn;
  - output has `runtimeStatus: "stopped"`, `handoff: "none"`, and no
    `revision`;
  - the next App launch uses it.
- App launch waits visibly ("Waiting for a local riela CLI operation…") while
  a CLI holds the lock.

**Behaviour change notes**

- `riela environment` without `--server` no longer targets
  `http://127.0.0.1:8787`; pass `--server` for `riela serve`.
- Instance commands without `--server` no longer use the App web server port.
- A one-time App upgrade is required. An older App has no channel, and local
  reload must not be used next to it; use `--server`.

**Error codes**

- Add a table of: `app_not_running`, `app_channel_unavailable`,
  `app_channel_insecure`, `app_channel_path_too_long` (hint: use a shorter
  `RIELA_APP_ROOT`, or `--server`), `app_channel_timeout`,
  `app_channel_protocol_error`, `request_too_large`, `invalid_request`,
  `request_id_conflict`, `channel_busy`.
- Keep the existing reload and cancel code tables.
- Update the `app_unreachable` line to say it applies to `--server` only.

Update every command synopsis to keep `[--server URL]` and add no new options.

### `README.md`

In the existing CLI section that links `docs/app-instance-control.md` (find it
with grep), add or adjust one short paragraph: "Without `--server`, instance
and environment commands talk to the local RielaApp over an owner-only Unix
socket (no web server needed); `--server URL` uses HTTP." Link the doc.
Nothing else changes.

## Verification (`tmp/serverless-app-control/sac-09/`)

- `mkdir -p tmp/serverless-app-control/sac-09`
- `git diff --check -- docs/app-instance-control.md README.md > tmp/serverless-app-control/sac-09/diff-check.log 2>&1`
  must exit 0.
- `grep -n "app_not_running\|control.sock\|app.lock\|--server" docs/app-instance-control.md > tmp/serverless-app-control/sac-09/grep.log`.
  All four terms must be present.
- `grep -n "RIELA_APP_SERVER\|--in-process" docs/app-instance-control.md README.md`
  must print nothing.
- `git diff --stat -- README.md` must show a small change in one hunk region.

## Done criteria

- The doc sections above exist.
- The README paragraph is present.
- The checks pass.
- The progress log records the commands and exit codes, using the drift rules
  from sac-01.
