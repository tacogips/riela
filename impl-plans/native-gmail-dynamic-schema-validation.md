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

Focused arm64 debug tests: 14 passed, no skips. Patch version is 0.2.46;
release/install and release-matched Linux acquisition image remain pending,
followed by the actual private source plan/resume/checkpoint gate.
No App migration or live provider verification is claimed by this runtime fix.
