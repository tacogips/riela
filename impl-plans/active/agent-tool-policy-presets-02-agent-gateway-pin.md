# atp-02-agent-gateway-pin: move agent-gateway to v0.1.5 (fbb7d851)

```json
{
  "planId": "atp-02-agent-gateway-pin",
  "planPath": "impl-plans/active/agent-tool-policy-presets-02-agent-gateway-pin.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Package.swift",
    "Package.resolved",
    "impl-plans/progress/atp-02-agent-gateway-pin.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

agent-gateway v0.1.5 (commit `fbb7d8519683d838d1f603480d5ec7a52700fe0e`) adds
`GatewayExecuteParams.webSearch: Bool`. atp-05 sets that field for the SDK
`web-search` preset. Design §5.

Today the pin is `Package.swift:71-72` with revision
`dae69561f05b75be6d680af1267da1af9db16d13`, and `Package.resolved` has the
matching `agent-gateway` entry. A repository-wide search confirms no other file
pins it.

Follow the shared worker protocol in
`impl-plans/active/agent-tool-policy-presets.md`.

This plan is the only owner of `Package.resolved`.

## Non-goals

- Do not move any other dependency.
- Do not edit Sources or Tests. If the bump breaks compilation, log every
  failing file and line for atp-05 (adapter files) or for serial
  reconciliation (any other file). Do not fix them here.
- No changes to the agent-gateway repository.

## File-level changes

- `Package.swift`: change only the revision string of the `agent-gateway`
  `.package(url:revision:)` entry to
  `fbb7d8519683d838d1f603480d5ec7a52700fe0e`.
- `Package.resolved`: produce it with
  `arch -arm64 /bin/zsh -lc 'swift package resolve'`, not by hand.
  - Afterwards, `git diff Package.resolved` must show only the `agent-gateway`
    revision and the top-level `originHash` changing.
  - If any other pin moved, restore that entry's previous revision and run
    `swift package resolve` again. Record the diff in the progress log.
  - If resolution is blocked (no network in the sandbox), record
    `blocked: network` with the exit status. Do not hand-edit the revision
    without the `originHash`. Serial reconciliation then runs the resolve.

## Tasks

- [ ] T1: Read both files fresh and record their pre-hashes.
- [ ] T2: Edit `Package.swift`, then run `swift package resolve` and save the
  log to `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/resolve.log`.
- [ ] T3: Confirm the resolved checkout and record the facts with line
  numbers.
  - `.build/checkouts/agent-gateway` is at `fbb7d851`. Check with
    `git -C .build/checkouts/agent-gateway rev-parse HEAD`.
  - `grep -n webSearch` over `.build/checkouts/agent-gateway/Sources` should
    show three things:
    1. `public var webSearch: Bool` in `Sources/AgentGateway/GatewayProtocol.swift`;
    2. no `webSearch` in `Sources/AgentGatewayAppCore/GatewayACPAgent.swift`;
    3. a webSearch rejection for cursorAPI in
       `Sources/AgentGatewayAppCore/GatewayAPIRequest.swift`.
  - Atp-05 relies on these facts. If any of them differs, log it and stop.
- [ ] T4: Run `swift build` and record the result. List any compile errors by
  file.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift package resolve > tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/resolve.log 2>&1'`
  must exit 0.
- `git diff --stat Package.swift Package.resolved` must show exactly these two
  files changed. The content diff must be limited as described above.
- `arch -arm64 /bin/zsh -lc 'swift build > tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/build.log 2>&1'`
  should exit 0. A non-zero exit caused by API drift in a file outside this
  plan is logged with each `file:line: error` and handed off. It is not fixed
  here.

## Done criteria

- `grep -c fbb7d8519683d838d1f603480d5ec7a52700fe0e Package.swift Package.resolved`
  gives 1 for each file.
- `grep -c dae69561 Package.swift Package.resolved` gives 0 for each file.
- The progress log records the v0.1.5 facts with line numbers, the resolve
  and build records, and any handed-off compile errors.
