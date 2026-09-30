# wh-10: Host traits and trait-aware placement

```json
{
  "planId": "wh-10-host-traits",
  "planPath": "impl-plans/active/wh-10-host-traits.md",
  "wave": "W2",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaWork/BackendCapabilityPlacement.swift",
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaAppSupport/DaemonWorkflowSupport.swift",
    "Sources/RielaCLI/DistributedWorkerCommand.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaCLI/DoctorCommand.swift",
    "Tests/RielaWorkTests/BackendCapabilityPlacementTraitsTests.swift",
    "Tests/RielaCLITests/HostTraitsResolverTests.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "impl-plans/progress/wh-10-host-traits.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-10-host-traits.md"
}
```

## Intent and context

A presence handover (S2) may be taken over only on a host that declares the required traits (for example
`userReachable`). Traits are declared, never probed. Design §3.8, §10.3, §21 R5 and R10, and QA Q7 (per-invocation
`--traits` allowed and recorded). `HostTrait` and the `traits` fields on `HostCapabilitySnapshot` and
`DistributedWorkerRegistration` come from wh-01.

Non-goals: CLI `--traits` parsing (wh-15 and wh-18 pass the values in), the takeover flow (wh-14), and GraphQL.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-10-host-traits/`,
writePaths only, arm64 logs, no git state changes, own progress log).

## Deliverables

- `BackendCapabilityPlacementResolver.resolve(requirements:local:workers:assignments:requiredTraits: [HostTrait] = [])`
  (new trailing defaulted parameter; existing callers compile unchanged). When `requiredTraits` is non-empty,
  a host is a candidate only if `Set(snapshot.traits) ⊇ requiredTraits`. If no live host qualifies, return
  the existing failure shape with reason `host-traits-unavailable: <sorted comma list>`. Use the same structure as
  `backend-unavailable:` (read `BackendPlacementFailure`, `:35`). Traits apply to the whole attempt,
  so check them per requirement host exactly like backend availability.
- `RielaAppDaemonWorkflowState.hostTraits: [HostTrait]`, decoded with **`decodeIfPresent` default `[]`**.
  This is a user profile file, so existing profiles must keep loading. Encode it always. Follow how the
  other fields are handled in its custom CodingKeys and init.
- `HostCapabilityResolver`: the local snapshot (`:137`) gets `traits = profile.hostTraits ∪ localTraitOverride`.
  `localTraitOverride: [HostTrait]` is a new stored property, default `[]`, settable by callers (wh-14/wh-15/wh-18).
  `taskTopology` carries the traits through unchanged.
- Workers: `DistributedWorkerCommand.Configuration` gains an optional `traits: [HostTrait]?` (`worker.json`). Pass it into
  `DistributedWorkerRegistration(traits:)`. `DistributedWorkerHTTPRouter.swift:198` copies `registration.traits` into
  the controller-side `HostCapabilitySnapshot`.
- `DoctorCommand`: the text line `host traits: <comma list>` or `host traits: none declared`, and a JSON field `hostTraits`,
  next to the backend table.

## Pitfalls

- Do not probe anything (no TCC or GUI checks). Declared only.
- An unknown trait string in `worker.json` must fail config decoding with the offending value named (strict enum).
- Keep the result order deterministic (sorted traits in messages).

## Tests

`BackendCapabilityPlacementTraitsTests`: local without traits and required `[userReachable]` → failure
`host-traits-unavailable: userReachable`; local with it → chosen; worker A without and worker B with → B chosen;
empty required → unchanged behavior (compare with an existing test fixture).
`HostTraitsResolverTests`: a profile JSON without `hostTraits` loads (`[]`); a profile with traits → local snapshot traits;
the override is merged; a worker config with `traits` → registration traits; an unknown trait → decode error.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-10-host-traits/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-10-host-traits/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "BackendCapabilityPlacementTraitsTests|BackendCapabilityPlacementTests|HostTraitsResolverTests|DoctorCommand|DistributedWorker" > tmp/work-handover/wh-10-host-traits/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-10-host-traits/focused.log'
git diff --check
```

Both must end with exit=0, the new tests must pass, and the existing placement, doctor and worker suites must be green or baseline-classified.

## Done criteria

- [ ] Traits flow from the profile, override and worker.json into snapshots, placement and doctor
- [ ] The tests pass; the progress log is complete


## Scope amendment (2026-09-30)

Run session-1 blocked this plan twice, correctly, because carrying `worker.json` traits into worker registration needs files the original `writePaths` omitted. They are now owned by this plan and no other plan touches them:

- `Sources/RielaServer/DistributedWorkerLoop.swift`: pass configured traits into the registration request.
- `Sources/RielaServer/DistributedWorkerProtocol.swift`: add `traits` to `DistributedWorkerRequest` registration (strict decode, as `DistributedWorkerRegistration` does since wh-01).
- `Sources/RielaCore/DistributedJobController.swift`: accept traits in `register` and persist them on the registration and worker status.
- `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`: assert that a registered worker's traits reach the controller status.

wh-01 through wh-09 and wh-11 through wh-13 are accepted and committed (`d043cbad`). Build on them; do not re-implement them.

- `Sources/RielaCore/DistributedWorkerModels.swift` (added after run session-2): add `traits` to `DistributedWorkerStatus` so worker status and doctor show them. The partial wh-10 implementation from session-2 is committed; complete it rather than restart.
