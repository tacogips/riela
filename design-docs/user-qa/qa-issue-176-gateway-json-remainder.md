# Issue #176 remainder (2026-10-25): decisions taken by default

None of these blocks implementation. Each one records the default the design
adopted (`design-docs/specs/design-gateway-sdk-addons.md`, "#176 remainder"),
so the user can overturn it later.

1. **`workflow run` reports gateway validation as warnings only.** The
   production context runs before effects. Its extra findings go to stderr as
   `warning:` lines and do not block the run, because a node on a branch the
   run never takes would otherwise block a run that succeeds today.
   Making it blocking, or adding an opt-in flag, would need a `workflow.run`
   surface and GraphQL `executeWorkflow` change. Default: warnings only (R1).
2. **Structured failure output is X-only and opt-in.** `providerFailure:
   "output"` exists only on the two X readers. Other gateways keep their
   current failure behavior. Default: X readers only (R2).
3. **Nested X `select` stays without a deprecation warning.** It is
   documented as a compatibility alias with a conversion rule. No validate
   warning is added. Default: keep it silently supported (R3).
4. **Google Service `allPages` stays.** It is an existing internal pagination
   option. It is kept for compatibility, is not used by the new examples, and
   is not extended. Default: keep (R5).
