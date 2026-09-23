# Controller and workers

The source build supports worker registration, targeted execution and result
delivery through RielaApp or `riela serve`. macOS and Linux ARM64 execution have
been verified across a VM network boundary in both controller directions.
Explicit bounded output files, Tauri controller settings and workflow placement
editing are supported.

The controller owns workflow state and dispatch. Workers connect outbound over
HTTP(S), execute nodes and return results. A worker needs a reachable controller
address: use a LAN/VPN or an HTTPS reverse proxy. Workers do not need inbound
ports or access to the controller's filesystem.
The listener admits at most 128 simultaneous connections and requires a complete
HTTP request within 15 seconds of accepting a connection. Sending partial data
does not extend this deadline.

## Controller configuration

Create `controller.json` on the controller machine:

```json
{
  "host": "0.0.0.0",
  "port": 8788,
  "storePath": "distributed/jobs.json",
  "workers": [
    {
      "id": "linux-1",
      "groups": ["linux", "build"],
      "tokenEnvironment": "RIELA_LINUX_WORKER_TOKEN",
      "maxCapacity": 2
    }
  ]
}
```

Set `RIELA_LINUX_WORKER_TOKEN` to a unique secret of at least 32 printable ASCII
characters, using the same value on that worker. Each worker has its own token,
ID and controller-authorized groups. `storePath` is relative to the configuration
file unless absolute. Keep it on the controller's local filesystem.

For CLI hosting:

```sh
export RIELA_CONTROLLER_CONFIG=/absolute/path/controller.json
riela serve
```

The worker listener uses the configured port independently of the web dashboard.
Local `riela workflow run`, `session resume` and `session rerun` processes use
the same `RIELA_CONTROLLER_CONFIG` to access the process-locked queue.

For RielaApp, place `controller.json` in the active profile directory, normally
`~/.riela/rielaapp/profiles/default/`. Put the token assignment in the adjacent
`controller.env` file when launching the app through Finder. The menu's
**Worker Controller Settings...** opens Tauri Settings to edit the listen address,
port, queue storage, worker IDs, groups, token variable names and capacities.
Use **Edit credentials…** to open the private `controller.env` file.
**Save and restart controller** persists the settings and restarts the listener after
queued/running jobs have finished or been cancelled. This check also applies while the controller
is stopped. Saving is atomic with respect to local queue submissions. Processes
that loaded a superseded configuration must reload it before submitting work.
The app starts a
configured controller automatically; **Start Worker Controller** and **Stop
Worker Controller** control it independently of the web server. No separate
`riela serve` process or web assets are required for the worker listener.
`RIELA_CONTROLLER_CONFIG` overrides the profile configuration location.
Profile switches stop the previous listener and use the new profile's credentials
and queue. Settings reload on a profile switch; stale profile or configuration
drafts are rejected when saving. For direct access from other machines, change
the default loopback listen address to an appropriate reachable interface (for
example, `0.0.0.0` to listen on all IPv4 interfaces). The debug executable's
`--open-worker-settings` option opens Tauri Settings on launch.

The app's **Worker Status...** menu shows configured worker IDs, their groups,
online/offline state and active job counts. On the controller machine, use
`riela worker status --config /absolute/path/controller.json` for JSON status.
Workers become offline after 30 seconds without a claim or lease renewal.
Status output contains no bearer token or incarnation/lease credentials.
The debug executable's `--open-worker-status` option opens the same status
dialog after starting the configured controller.

## Worker configuration

On the worker machine, create a configuration pointing to a reachable controller:

```json
{
  "controllerURL": "https://controller.example.com",
  "tokenFile": "worker.token",
  "capacity": 2,
  "workspaces": {
    "project": {
      "path": "/srv/project",
      "controllerPath": "/Users/operator/project",
      "allowedAddons": [],
      "allowedEnvironment": ["OPENAI_API_KEY"]
    }
  }
}
```

Save the worker's controller-authorized token as plain text in `worker.token`
beside `worker.json` (an optional trailing LF or CRLF is accepted). Restrict the
token file to its owner, for example with `chmod 600 worker.token`. `tokenFile`
accepts an absolute path or a path relative to `worker.json`. This lets the worker
start using files without exporting credentials in the launching shell.
Alternatively, replace `tokenFile` with
`"tokenEnvironment": "RIELA_LINUX_WORKER_TOKEN"` to read an environment variable.
Specify exactly one of these two fields. The controller assigns the worker ID
and groups based on the matching token in its configuration.

`path` must be an existing worker directory. Relative paths are resolved beside
the worker configuration file. Provision the repository, executables and agent
credentials on each worker. The optional `controllerPath` maps authored absolute
working directories from the controller into this workspace. Unknown workspaces
and paths escaping their mapped root are rejected. This path mapping is not a
process sandbox; commands execute with the worker user's permissions.

Each workspace's `allowedEnvironment` lists host environment variables available
to its nodes, including provider credentials and optional executable overrides.
Only PATH, HOME, USER, LOGNAME, SHELL, TMPDIR, LANG, LC_ALL, LC_CTYPE and TZ are
inherited by default. The configured `tokenEnvironment` is always excluded, even
if listed. Required agent/add-on bindings to unavailable variables fail. Commands
and container add-on launchers also use this filtered environment. This controls
environment inheritance; it does not prevent authorized code from reading files
accessible to the worker OS account. The `riela/workflow-create-register-run`
add-on must remain on the controller because it creates and launches a separate
workflow runtime outside the worker workspace configuration.

For direct HTTP on an operator-controlled LAN/VPN, set `controllerURL` to
`http://<controller-address>:8788` and explicitly set `allowInsecureHTTP: true`.
Loopback HTTP is accepted without that option. Redirects are never followed.

```sh
riela worker --config /absolute/path/worker.json
```

Install the same source/version on controller and workers. `capacity` cannot
exceed that worker's configured `maxCapacity`. Add a separate controller worker
record and token for every additional worker machine.

## Select execution location

Add placement to a workflow step:

In Workflow studio, select a step, set **Run on** to **Remote worker**, then enter
the worker workspace and optional worker ID/group. **Export files** accepts one
workspace-relative path per line. Save the workflow to persist the placement.
Choose **This controller** to remove remote placement. The equivalent JSON is:

```json
{
  "id": "compile",
  "nodeId": "compile-command",
  "placement": {
    "target": { "workerId": "linux-1" },
    "workspace": "project",
    "exports": ["build/report.json"]
  }
}
```

Use `"target": {"group": "build"}` to select any eligible worker in that group.
When both ID and group are supplied, both must match. An empty target object
allows any remote worker. Omitted placement retains local execution. Explicit
placement never falls back to local execution when a worker is unavailable.

Optional `exports` lists files to return after successful execution, relative to
the worker workspace root (not the node's working directory). List at most 16
unique regular files, totaling at most 512 KiB. Absolute paths, traversal and
symlinks are rejected. A missing or oversized export fails the node. Provision
input repositories and large build assets separately; this channel carries
bounded reports and results, not entire workspace synchronization.

The controller verifies each file's SHA-256 and saves it with private permissions
under `<storePath>.artifacts/<sha256>`. Original paths remain manifest labels;
exports never overwrite controller project files. Session `remote.artifact`
events report the original path, controller-local path, digest and byte count.
The queue snapshot retains the bytes and can restore a missing artifact file.
Result JSON including base64-encoded exports must fit the 1 MiB completion limit.

Agent bindings using `fromEnv` resolve on the worker. Executable add-ons must
also be in that workspace's explicit `allowedAddons` list. Controller-only
projection and Git finalization operations cannot be assigned to workers.

Leases are renewed while executing and publishing results. A lost lease stops
the worker invocation and fences stale results. Cancelling one job stops its
process tree while the worker remains available for other jobs. A fenced worker
registration still stops the worker process. An uncertain execution is marked
`lost`; it is not automatically replayed because external side effects may have
occurred. Explicit workflow retry is required. Structured output and command
evidence return to the controller. Ordered backend events stream to the session;
the controller retains the most recent 128 events per job, and reports gaps when
a reader misses older events. Oversized individual events are replaced with a
truncation marker. Only files declared in `exports` are transferred.

Node failures retain their category (policy denied, invalid input, timeout,
invalid output or provider failure) with bounded diagnostic guidance. Arbitrary
provider error text is not copied across machines. The workflow event stream
also records the assigned worker ID, workspace and job ID.

## Controller history and capacity

The active snapshot retains at most 16 full terminal job records. Older terminal
records move to private, digest-verified files in `<storePath>.history`; compact
job IDs, status and lease references remain in the snapshot. Workflow reattachment
and completion retries load individual records, preserving results and duplicate
protection without decoding all historical payloads on every poll. Library callers
use `job(id:now:)` for full history; `jobs(now:)` marks compact entries with
`archived: true`.

A store accepts at most 32 unfinished jobs and 10,000 total job IDs. Admission
reserves up to 5 MiB per unarchived job against a 1 GiB history budget; result and
event limits remain smaller. Snapshot reads/writes are capped at 512 MiB, and
individual historical records at 5 MiB. A capacity error rejects new work before
it is accepted, leaving room for existing jobs to finish. No history is silently
deleted. Once all jobs are finished or cancelled, operators can preserve the old
store together with its `.history` and `.artifacts` directories and select a new
`storePath` through controller settings. Keep the original store configuration
when inspecting or resuming its sessions; a new store does not contain their
execution history. Back up the snapshot and its companion directories together.
