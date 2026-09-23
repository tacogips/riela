# Expected results

- Workflow validation succeeds with entry step repair and required gate verification at step verify.
- The bundled mock workflow run executes repair then verify, completes, and records an accepted verification gate with acceptance.met true.
- A task lifecycle fixture with a matching acceptance criterion and passing verification evidence may be accepted by the deterministic director after terminal projection.
- A rejected gate with remaining attempt budget requests recovery from verification; exhausted or repeated guard violations stop or require a human according to the task policy.
- Capacity wait creates no attempt, reserved session, or lease.

The standalone workflow run covers only the first two points. TaskRuntimeExampleTests must assert the remaining task ledger, decision, and reservation outcomes.
