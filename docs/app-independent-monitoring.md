# App-independent health and output monitoring

A monitor hosted by RielaApp shares the App's failure boundary: if the App
crashes or is quit, its event listeners stop, and the monitor cannot report that
the monitored workflow stopped. For a scheduled workflow that must be watched
reliably, run the monitor **outside** the App. Use an OS scheduler such as launchd
or systemd, and invoke `riela session monitor`.

The monitor is read-only and bounded. It never launches, cancels, or restarts
workflows or RielaApp. Restarting the App remains an explicit operator decision.

## `riela session monitor`

```sh
riela session monitor --workflow <workflow-id> --max-output-age-seconds <n> \
  [--session-store <dir> | --scope project|user --working-dir <dir>] \
  [--event-root <dir> --scheduler-max-silence-seconds <n> [--event-source <source-id>]] \
  [--require-app [--app-profile <name>]] \
  [--timeout-seconds <n>] [--output json|text]
```

The check reads the session store's root executions of `--workflow`. Nested child
executions are ignored. It reports one verdict:

| Verdict | Exit | Meaning |
| --- | --- | --- |
| `healthy` | 0 | The newest completed execution is younger than `--max-output-age-seconds`, and every requested dependency is up. |
| `running` | 0 | Output is older than the limit, but a live root execution holds its execution lock. Re-check later. |
| `stale_output` | 3 | Output is older than the limit, or absent, and nothing is running. |
| `scheduler_unavailable` | 3 | With `--event-root`, no receipt was written within `--scheduler-max-silence-seconds`. Use `--event-source` to count only one source. |
| `app_unavailable` | 3 | With `--require-app` (macOS), RielaApp is not running, or its control queue did not answer a bootstrap request in time. |
| `check_failed` | 1 | The store or receipts could not be read within `--timeout-seconds`. This includes an unreadable store and a stalled or unmounted volume. |

Verdict priority is `check_failed` > `app_unavailable` >
`scheduler_unavailable` > `running`/`stale_output` > `healthy`. A monitor can
therefore tell a host outage from a scheduler outage, a long run, stale output,
and its own failure. Exit 2 is invalid usage.

The JSON report includes `reasons`, `store.lastCompleted`, `store.latestTerminal`,
`store.outputAgeSeconds`, `store.liveSessionIds`, `scheduler.lastReceiptAt`,
`scheduler.silenceSeconds`, and `app.state`. `app.state` is one of `running`,
`not_running`, `unresponsive`, `busy`, or `unsupported`.
`store.orphanedSessionIds` lists `running` records that have no live runner,
such as those left by a crash or a disk-full failure. Reconcile them with
`riela session reconcile --apply`. RielaApp also reconciles records in its
profile store automatically (see
[session cancellation and reconciliation](session-cancellation-and-reconcile.md)).

Every store and receipt read runs on its own thread with a deadline. A blocked
`open(2)` cannot hang the monitor. It reports `check_failed`. While the earlier
probe of that store is still blocked, subsequent checks in the same process fail
fast.

## launchd deployment (macOS)

Run the check from a per-user LaunchAgent. The agent belongs to launchd, not
RielaApp, so it continues to run when the App is down. This example checks every
30 minutes that an hourly workflow produced output in the last two hours and that
its cron source is still ticking:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>me.example.riela.hourly-monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>/opt/homebrew/bin/riela session monitor --workflow hourly-collect --max-output-age-seconds 7200 --session-store "$HOME/.riela/profiles/default/sessions" --event-root "$HOME/work/hourly/.riela/events" --scheduler-max-silence-seconds 7200 --require-app --output json || /usr/bin/osascript -e 'display notification "riela hourly-collect monitor is unhealthy" with title "riela"'</string>
  </array>
  <key>StartInterval</key><integer>1800</integer>
  <key>StandardOutPath</key><string>/Users/me/Library/Logs/riela-hourly-monitor.log</string>
  <key>StandardErrorPath</key><string>/Users/me/Library/Logs/riela-hourly-monitor.log</string>
</dict>
</plist>
```

Load it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/me.example.riela.hourly-monitor.plist`.
Replace the notification with your own alert hook. The hook can be a script that
posts to chat, or `riela workflow run <alert-workflow>` with
`--runtime-environment-file` (see below). Keep the log on a volume other than
the one the monitored store fills, or on the same volume when it has headroom.
Riela itself never crashes because its log volume is full: diagnostics that
cannot be written are dropped.

To run a full monitoring **workflow** on a schedule outside the App, rather than
only the bounded check, run a dedicated `riela events serve` from launchd for
the monitor's own event root:

```sh
riela events serve --event-root "$HOME/work/monitor/.riela/events" \
  --session-store "$HOME/.riela/monitor/sessions" \
  --runtime-environment-file "$HOME/work/monitor/runtime-environment.json"
```

Set `KeepAlive` to restart this listener only, never RielaApp. Give the monitor
its own session store. The monitor then does not share the monitored store's
volume or retention.

## Credentials

Keep credential resolution inside Riela. An external service passes an explicit
runtime-environment descriptor (`--runtime-environment-file`). The descriptor
names loaders, and Riela resolves secrets when it runs. Do not put secret values
in the plist, unit file, default variables, or command arguments. Do not write a
helper that reads the secret store itself. `riela session monitor` needs no
credentials. It only reads the session store and receipts.

## Handing ownership from an App-managed monitor to an external scheduler

Two monitors that watch the same workflow send duplicate alerts. To transfer
ownership without a gap or overlap:

1. Install the external agent with `RunAtLoad` false. Run it once by hand
   (`launchctl kickstart gui/$(id -u)/<label>`) and confirm a `healthy` verdict.
2. In RielaApp, deactivate the App-managed monitor instance, or remove its
   cron binding with `riela instance reload <id> --reason 'monitor moved to launchd'`.
   Confirm that `riela events list --event-root <monitor-root> --limit 1` shows no new receipts after the
   next scheduled tick.
3. Enable the external agent's schedule (`launchctl enable` /
   `bootstrap`). Only one owner now fires checks.
4. To move ownership back, reverse the order. Disable the external agent first,
   then reactivate the App instance.

Do not configure the external check to restart RielaApp automatically. If an
operator wants automatic restarts, add them as a separate, explicit opt-in step
in the alert hook. A recovery policy that holds writes during an incident
remains possible because the monitor itself never acts.
