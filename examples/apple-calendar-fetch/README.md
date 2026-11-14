# Apple Calendar Fetch

This read-only example lists Apple Calendar calendars and fetches upcoming
events through the built-in `riela/calendar-list` and `riela/event-search`
add-ons. It does not create, update, delete, or modify alarms.

The `apple-gateway` code is linked into `riela`; there is no executable to
install, no `APPLE_GATEWAY_BIN`, and no `binaryPath` add-on config. macOS
attaches Apple permission grants to the executable that asks, so grants given
to a standalone `apple-gateway` do not carry over — approve `riela` once from
an interactive run before using this from a daemon.

```sh
apple-gateway permissions request --domain calendar
apple-gateway permissions status --json
swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples
swift run riela workflow run apple-calendar-fetch \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"calendarIds":["<calendar-id>"],"startDate":"2026-07-07T00:00:00Z","endDate":"2026-07-14T00:00:00Z"}}'
```

Use a read-only Apple Gateway calendar-list query to identify calendar ids,
then pass at least one explicit id to this workflow. `riela/event-search`
rejects an empty `calendarIds` array, keeping event fetching opt-in and scoped
to calendars selected by the caller.
