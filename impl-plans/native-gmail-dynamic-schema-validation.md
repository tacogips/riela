# Request-bound agent schema composition

ART's private Gmail acquisition uses a static tool-free agent with
`output.jsonSchemaFrom: /runtimeVariables/inspector_schema`, then a native
JSON composer that combines its checked IDs with the immutable request context.
Static workflow validation incorrectly requires a fixed `output.jsonSchema`
when a downstream template references the agent's output, rejecting this
otherwise supported execution path.

Allow the existing request-bound contract wherever static validation requires
an agent output contract. Its properties cannot be enumerated at load time;
runtime schema resolution/validation still happens before adapter invocation
and publication. Missing/invalid schema pointers still fail closed. Existing
fixed-schema field checks are unchanged.

Validation:

- AgentNodeOutputContractValidationTests covers downstream references,
  conditional labels and invalid pointers.
- NodeOutputContractResolutionTests covers missing/unsupported runtime schemas,
  static-plus-dynamic composition, adapter contracts and rejected publication.
- Actual ART `gmail-acquisition-screen` / source graph validation must pass
  with the resulting CLI; the old 0.2.45 CLI reproduces the loader failure.
- Actual Opus 5.5 medium review found no blocker; proof is in
  tmp/claude-opus55-review/native-gmail-dynamic-schema-proof.json.

Focused arm64 debug tests: 14 passed, no skips.

Release/install evidence (2026-10-23):

- v0.2.46 is published at immutable source
  `0c991521228cd8e7aa38a6c58f094cc875ee7e62`, with all three architecture
  archives and SHA256 sidecars. Linux arm64/x64 release run `39890493986`
  and main amd64 CI `39890460797` completed successfully at that same source.
- macOS archive SHA256 is
  `8ed6e0d3837c4270ee51c1fc2cab369c99dd4467bcc00b4cf5f668b25ebce7d2`.
  Downloaded Linux arm64 and x64 archives match their published sidecars.
- Homebrew tap commit `1256957` updates the formula. The local installation
  reports 0.2.46, `brew test tacogips/tap/riela` passes, and the installed
  executable SHA256 matches the tested release executable exactly.
- ART's release-matched `art-native-agents:0.2.46-acquisition` image passes
  all 14 Gmail acquisition tests without skips. The actual private guest
  runs with network denied and only gateway/model leaves replaced by offline
  fixtures. Source plan/resume commits one checked record through native-backed
  checkpoint storage; rejected raw content and synthetic credentials do not
  appear in host session/artifact files. Evidence is under ART's
  `.runtime/art-verification/native-gmail-private-046-tests.log` and
  `native-gmail-private-proof.json`.

No App migration or live provider verification is claimed by this runtime fix.
ART's remaining Python orchestration and production cutover remain in scope.
