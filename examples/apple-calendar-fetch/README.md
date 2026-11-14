# Apple Calendar Fetch

This read-only example lists Apple Calendar calendars and fetches upcoming
events through the built-in `riela/calendar-list` and `riela/event-search`
add-ons. It does not create, update, delete, or modify alarms.

Install or build `apple-gateway` outside this repository, then make it
available either with `APPLE_GATEWAY_BIN` or with `addon.config.binaryPath`.

```sh
apple-gateway permissions request --domain calendar
apple-gateway permissions status --json
swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples
APPLE_GATEWAY_BIN=/path/to/apple-gateway swift run riela workflow run apple-calendar-fetch \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"calendarIds":["<calendar-id>"],"startDate":"2026-07-07T00:00:00Z","endDate":"2026-07-14T00:00:00Z"}}'
```

Run once without `calendarIds` or with a known read-only Calendar listing flow to
identify calendar ids, then pass explicit ids for event search. The example
keeps `calendarIds` in `workflowInput` so event fetching is opt-in and scoped to
calendars selected by the caller.
