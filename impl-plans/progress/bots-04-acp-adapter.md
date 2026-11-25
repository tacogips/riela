# bots-04-acp-adapter progress

**Status** — Implementation verified on the shared branch. Independent review pending.

## Implemented

- ACP v1 and v2 updates carry typed activity. The v1 wire fallback keeps open plan priority, plan status, and tool kind strings that the pinned v1 decoder cannot represent. The v2 collector emits both config and mode activity when the agent reports a mode. Non-text payloads produce discriminator-only activity.
- Existing assistant, thought, and tool event fields are preserved. Terminal metadata emits usage, model, then stop in order. Structured rate and usage limits carry the optional reset time. Missing and future stop reasons retain their metadata and fail the turn.
- The adapter relays native permission choices to the runtime handler. It declines absent handlers and unoffered option IDs. Cancellation and deadline tests verify receipt of the cancelled reply by each scripted protocol endpoint before transport teardown.
- The `default` node model uses the gateway's existing empty-model value. Adapter output uses the reported model when present and falls back to the sentinel for an unreported default.
- Scripted v1 and v2 transports exercise update ordering, out-of-order tool patches, plan replacement, terminal errors, and permission responses.

## Per-edit hashes

The prior Riela snapshot had 42 entries and matched the original scoped file content. Exact edit intentions and all hash transitions are in `tmp/bots-overview/bots-04-acp-adapter/edit-intentions.md` and `tmp/bots-overview/bots-04-acp-adapter/edit-hashes.tsv`. The ten changed Swift files matched the final recorded hashes and the final test command's before and after manifests were identical.

| Path | Before SHA-256 | After SHA-256 |
| --- | --- | --- |
| `Sources/RielaAdapters/GatewayActivityMapping.swift` | `absent` | `5e5d91dd34afb997cce4ce6ca2316909e1523c431d1045d10dcf14c9f2b351c4` |
| `Sources/RielaAdapters/GatewayPermissionDelegate.swift` | `absent` | `e22c0b5580e5a0e3c21363f07136e479b0b0d462bf556720315a72754cd08036` |
| `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` | `d65f4f85d1e4d3f67a066b99583f4f6cb3e884e907fd6b18f3ec03d75f0e9e7a` | `8f1592f2b0b598aed3737a1496788205178310d4d8964987fdf26886073a9394` |
| `Sources/RielaAdapters/AgentGatewayACPV2Turn.swift` | `f2cf8bfa57fd691dfa85ea6e675ccf5496cddbdc7f6bf2a71114e49dce5ccef7` | `516d686682baee84822c3c43e28d9c84243a8913ed20768b2b81860b73e737df` |
| `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` | `8f1592f2b0b598aed3737a1496788205178310d4d8964987fdf26886073a9394` | `0c32d1f631f49508968302c3e4db3623620d150d5db434e9ad16176304e1e069` |
| `Tests/RielaAdaptersTests/AgentGatewayACPV2Tests.swift` | `32df4a0c69c5ff0a4dc7809c878546228236f187bd97fece52f495b32db3357b` | `1c9594934da19f9da5fa0dee0fb80e631451b30b8de4629b9cf1e22b301dc4f8` |
| `Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift` | `47e425c9c276985d4c914c22c739d0922c5e07e3afdd97e4c54630bc8982b468` | `79404bb5edba958ab119ff596c61431bb951aa5f6607910483c9ff7ef5bd7925` |
| `Tests/RielaAdaptersTests/ACPTranscriptFixtures.swift` | `absent` | `3fa249ffe675a53e5b29a297e971ba73d05fcadaa2e1295459021720c4ce5b17` |
| `Tests/RielaAdaptersTests/ActivityNormalizationTests.swift` | `absent` | `461d8ab3ad2a9153108d2f3357c8e654d8f37e19f70917835db8a1c42ff0f5da` |
| `Tests/RielaAdaptersTests/GatewayScriptedAgentTests.swift` | `absent` | `722c9d5a5f1a56529e638372f7434a6b72dbf2c8fb07e2e9858d43aee3e6b738` |
| `Tests/RielaAdaptersTests/GatewayModelSentinelTests.swift` | `absent` | `e3b4450a08127eaec51735116bd4570ac70bed6dabd403a0a4b1411303528288` |
| `Sources/RielaAdapters/GatewayPermissionDelegate.swift` | `e22c0b5580e5a0e3c21363f07136e479b0b0d462bf556720315a72754cd08036` | `cbe027192c363fdbc0bef6709acd5aac72df08c683b941814993337ac943bd4e` |
| `Tests/RielaAdaptersTests/GatewayScriptedAgentTests.swift` | `722c9d5a5f1a56529e638372f7434a6b72dbf2c8fb07e2e9858d43aee3e6b738` | `b9acb63ecdf4feb744852206af9ff7d3f5a4c1da06f024d675aa9108009ed48a` |
| `Sources/RielaAdapters/GatewayActivityMapping.swift` | `5e5d91dd34afb997cce4ce6ca2316909e1523c431d1045d10dcf14c9f2b351c4` | `6ec2740f5a79d7582e94bfadd17ca9a8c71388baca297a3ff5ebe6cc2d5a259c` |
| `Tests/RielaAdaptersTests/ACPTranscriptFixtures.swift` | `3fa249ffe675a53e5b29a297e971ba73d05fcadaa2e1295459021720c4ce5b17` | `113e131974a7c27c9297803522dd9d0951ee9cbcdacdcc3c8f6a282fb62fbc88` |
| `Tests/RielaAdaptersTests/GatewayScriptedAgentTests.swift` | `b9acb63ecdf4feb744852206af9ff7d3f5a4c1da06f024d675aa9108009ed48a` | `ffc8cbabcc0b032b5747eca5b851fdad7306bb995ce674adaba7cca46b6e823a` |
| `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` | `0c32d1f631f49508968302c3e4db3623620d150d5db434e9ad16176304e1e069` | `259f1793399b99543ea8f80051ec6d64e7720e23aae1a0f348d243f181102667` |
| `Sources/RielaAdapters/GatewayPermissionDelegate.swift` | `cbe027192c363fdbc0bef6709acd5aac72df08c683b941814993337ac943bd4e` | `c14373507d9e3fb22df443cac985b2d8129b2c3cde4043f99e45b3cfbc7aeb3f` |
| `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` | `259f1793399b99543ea8f80051ec6d64e7720e23aae1a0f348d243f181102667` | `b3c3dfd5403df0c338b27b6e1ca5db54b74af829810ab3bc510044afdda9a169` |
| `Sources/RielaAdapters/AgentGatewayACPV2Turn.swift` | `516d686682baee84822c3c43e28d9c84243a8913ed20768b2b81860b73e737df` | `f616598f666e21ea2599bf50e7788e108948bc1ccd4ca02e3486dba741f20094` |
| `Tests/RielaAdaptersTests/ActivityNormalizationTests.swift` | `461d8ab3ad2a9153108d2f3357c8e654d8f37e19f70917835db8a1c42ff0f5da` | `ed36daf4f816102532634e8ce93445354e89c104ebfa7aba1a903e441e400e7a` |
| `Tests/RielaAdaptersTests/GatewayScriptedAgentTests.swift` | `ffc8cbabcc0b032b5747eca5b851fdad7306bb995ce674adaba7cca46b6e823a` | `c3fbde506fa8dc6e611da84cf7edab2d9194ce1cc611b3e58ac69ebf7d700bb3` |
| `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` | `b3c3dfd5403df0c338b27b6e1ca5db54b74af829810ab3bc510044afdda9a169` | `417dcd115bd7a1bc3bb95ef682c5a55bea9f77cda9d1681d44936b0c52debfbd` |

## Verification

Evidence directory is `tmp/bots-overview/bots-04-acp-adapter/`.

| Command | Exit | Evidence |
| --- | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "ActivityNormalizationTests\|GatewayScriptedAgentTests\|GatewayModelSentinelTests\|AgentGatewayACPV2Tests\|AgentGatewayNodeAdapterTests\|AgentGatewayCancellationTests\|BackendWaitSignalClassifierTests\|GatewayTurnLifetimeTests"'` | 0 | `test-verified.log` reports 8 XCTest and 50 Swift Testing tests passed, with zero failures. |
| `xargs -0 swiftlint lint --strict --quiet --no-cache < changed-swift.nul` in the arm64 shell using the plan-local manifest | 0 | `swiftlint-stable.log` has no diagnostics for the ten changed Swift files. |
| `grep -n "GatewayClientPermissionResponder" Sources/RielaAdapters/*.swift` | 1 | `permission-responder.log` is empty, as required. |
| `grep -n "default:" Sources/RielaAdapters/AgentGatewayACPV2Turn.swift` | 1 | `v2-default.log` is empty, as required. |
| `git status --short -- .build Package.swift Package.resolved VERSION` | 0 | `protected-paths.log` is empty. |
| `git diff --check -- Sources/RielaAdapters Tests/RielaAdaptersTests impl-plans/progress/bots-04-acp-adapter.md` | 0 | `diff-check-final.log` is empty. |

Earlier test attempts are retained in `test-attempt-1.log` (sibling activity store compile), `test-attempt-2.log` (corrected v2 command shape), and `test.log` (sibling Swift isolation compile). `test-final.log` passed before the final transport cleanup edit was verified. `test-verified.log` is the current behavioral evidence. The earlier strict-lint nesting findings are in `swiftlint-attempt-1.log`.

## Deviations

The pinned v2 permission request uses a top-level title and a typed subject. The v1 request uses a top-level tool-call reference. The adapter handles both native shapes. The existing event-array tests assert the original assistant and thought channels and also check the expanded terminal suffix.

The canonical SwiftPM filter ran all required suites and gateway tests on the shared tree. Only the assigned Swift paths were source-hash matched for this verification.

## Open items

Independent test-integrity, adversarial, and serial integration reviews remain workflow-owned. The upstream gap for rich updates from the pinned production gateway remains documented in design section 15.
