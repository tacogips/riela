# Distributed controller and workers

Status: implemented and verified in the source tree on 2026-09-10; not a release announcement.

## Required outcome

RielaApp on macOS and `riela serve` on Linux must host the same controller
service. Multiple machines run workers, and workflow execution can target a
particular worker ID or a worker group. Local execution remains the default
for existing workflows. The app must not require a separately launched
`riela serve` process to enable remote workers.

Workers must also start from a configuration file. The file specifies the
controller connection, authentication source, execution capacity and local
workspaces, so startup does not require exporting the connection credentials in
the launching shell.

## Reference evidence

Inspected the local checkout of https://github.com/tacogips/kestra at commit
`0046dc48c4095c121c834038b13812299f65a82e` (2026-09-10).
`worker-controller/src/main/proto/connect_controller.proto` registers a worker
with a group and thread count. `worker_controller.proto` defines worker-initiated
bidirectional job streaming, capacity permits, completion IDs, results, logs,
and cancellation events. `ConfiguredWorkerQueueResolver.java` implements group
subscription resolution. Riela adopts worker-initiated capacity-based pulling
and explicit routing; an unavailable explicit target must never fall back to
local execution or an unrelated group.

## Architecture

- Shared controller library, embedded by app and CLI, owns durable job state.
  Workers connect outbound to an authenticated HTTP(S) endpoint. Use bounded
  polling initially with the existing Swift HTTP server; gRPC is not required.
  A LAN/VPN address or reachable HTTPS reverse proxy is required. Polling does
  not make an unreachable controller behind NAT reachable by itself.
- One controller owns a data root. Durable enqueue and claim precede a reply.
  Per-worker credentials bind authorized ID and groups at the HTTP boundary;
  workers cannot self-authorize a group or claim another worker's result.
- Each worker registration receives an incarnation token. Reconnection fences
  earlier incarnations. Every claimed job has a unique lease token; completion,
  heartbeat and cancellation use both identities.
- Capacity limits apply across all jobs for a worker. Explicit ID and group,
  when both supplied, are conjunctive. FIFO eligible work is claimed first.
- Lease expiration marks an execution lost. Do not automatically replay a job
  with potentially completed external effects. Retries are explicit workflow
  attempts and preserve existing operation/idempotency identities. Duplicate
  identical result submission is accepted; conflicting results are rejected.
- Persist execution location, outcome and failure evidence in controller-owned
  session records. Controller alone advances workflow transitions. Workers run
  resolved node invocations, including adapters and executable add-ons.
- Workers have explicit local workspace mappings and local credentials.
  Controller filesystem paths must not silently become worker paths. Transfer
  required prompts/attachments and result artifacts with bounded sizes and
  verified digests. Never distribute controller environment wholesale.
  The initial output channel uses explicit `placement.exports` workspace-relative
  paths: at most 16 regular files totaling 512 KiB, carried in the authenticated
  completion message with SHA-256 digests. Controller content-addressed storage
  never uses worker labels as destination paths. The full encoded result is
  limited to 1 MiB. Input workspaces and large build assets are provisioned by
  operators; this does not implement unrestricted workspace synchronization.
- Existing local execution, nested workflows, cancellation, deadlines and live
  logs must retain their contracts. Privileged controller operations stay on
  the controller; remote invocation must not grant manager credentials.
- App preferences expose controller enablement/listen address and workers;
  profile changes stop the old controller before changing data/auth roots.
  CLI offers matching controller configuration and a worker process command.

## Configuration-file startup and connection contract

Controller configuration and worker configuration are separate JSON documents:
the controller authorizes worker identities, while each worker specifies how to
connect and which local resources it can use.

### Worker configuration

Start a worker with `riela worker --config /absolute/path/worker.json`:

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

- `controllerURL` is the reachable controller endpoint. HTTPS is the default
  transport requirement; loopback HTTP is accepted. Non-loopback HTTP requires
  an explicit `"allowInsecureHTTP": true`. Redirects are rejected.
- Specify exactly one of `tokenFile` or `tokenEnvironment`. `tokenFile` points
  to a plain-text bearer token, using an absolute path or a path relative to
  `worker.json`; one trailing LF or CRLF is accepted. Keep this file private
  (for example, mode `0600`). Alternatively, use
  `"tokenEnvironment": "RIELA_LINUX_WORKER_TOKEN"` to resolve the token from
  the worker process environment. The token must match the controller's record.
- The worker does not choose its own ID or groups. Registration returns the
  identity authorized by the matching controller credential. `capacity` must
  be positive and cannot exceed that identity's `maxCapacity`.
- `workspaces` must contain at least one named, existing local directory.
  Relative `path` values resolve against the configuration directory.
  `controllerPath` optionally maps authored controller working directories
  into the worker's local root; unknown workspaces and escaping paths fail.
- Each workspace explicitly permits executable add-ons through `allowedAddons`
  and additional inherited environment variables through `allowedEnvironment`.
  The transport token's `tokenEnvironment` variable is always excluded from
  node environments, even when listed. The baseline environment and deployment
  procedure are documented in [the operator guide](../../docs/distributed-workers.md).
  These controls do not replace the worker OS account's filesystem permissions.

Configuration is loaded when the worker process starts. Operators provision the
workspace, executables and node credentials on that machine, then restart the
worker to apply configuration changes. Each additional worker uses its own
controller-authorized token.

### Controller configuration and hosting

The corresponding `controller.json` authorizes the worker and owns queue storage:

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

The controller resolves `tokenEnvironment` locally. Its value must equal the
worker's token, regardless of whether that worker uses a token file or an
environment variable. Use a unique token of at least 32 printable ASCII
characters per worker. Relative `storePath` values resolve beside the controller
configuration and refer to controller-local durable storage.

For CLI hosting, set `RIELA_CONTROLLER_CONFIG` to the absolute configuration path
and run `riela serve`. The worker listener uses its own configured port.
Controller-local workflow run/resume/rerun processes use the same configuration
to access the process-locked queue.

RielaApp automatically hosts the same controller from the active profile's
`controller.json`, normally under `~/.riela/rielaapp/profiles/default/`.
Adjacent `controller.env` supplies credentials for Finder launches;
`RIELA_CONTROLLER_CONFIG` overrides the configuration location. The native
**Worker Controller Settings...** window edits this configuration and provides
**Edit Credentials…** and **Save and Restart**. No separate serve process or
web assets are required.

App start/stop, settings saves and profile switches are serialized. Configuration
replacement requires an idle queue, including when the listener is stopped;
the idle check and write share the queue lock. Processes holding a superseded
configuration must reload before submitting work. Profile changes stop the old
listener before switching storage and credentials, and close old settings drafts.

### Placement and configuration ownership

A workflow step refers to the controller-authorized identity and a worker-local
workspace name; it contains no connection credentials:

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

Use `"target": {"group": "build"}` for group selection. Supplying ID and group
requires both to match; an empty target selects any eligible remote worker.
Omitting placement preserves local execution. An unavailable explicit target
never causes local fallback. Connection settings belong to deployment files,
identity authorization belongs to the controller, and execution placement belongs
to the workflow.

## Completion gates

1. Routing schema, validation and precedence tests; no implicit fallback.
2. Durable queue, restart, capacity, incarnation/lease fencing, expiration,
   cancellation, duplicate/conflicting result and concurrent claim tests.
3. Authenticated transport, credential-to-worker binding, bounded bodies,
   endpoint/TLS validation, reconnect and result acknowledgement tests.
4. Real adapter/add-on execution and artifacts across separate processes with
   two workers; verify exact worker and group targeting and returned output.
5. App-owned controller and CLI serve use the same implementation; verify app
   start/stop/profile switch and worker status UI with current executable.
6. Linux build/run verification, macOS app verification, documentation and
   reproducible separate-machine setup instructions.
7. Independent review plus relevant Swift, lint and UI checks. No completion
   claim based only on in-memory broker or loopback protocol tests.
8. Worker startup from JSON with connection settings, token-file and environment
   authentication, relative paths, and rejection of invalid authentication choices.

## Verification record

All completion gates were checked against the current implementation. See
[`impl-plans/completed/distributed-workers.md`](../../impl-plans/completed/distributed-workers.md)
for platform tests, network execution, review findings and operational bounds.
