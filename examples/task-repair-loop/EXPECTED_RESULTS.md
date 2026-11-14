# Expected results

- Workflow validation succeeds with entry step repair and required gate verification at step verify.
- The bundled mock workflow run executes repair then verify, completes, and records an accepted verification gate with acceptance.met true.
- A standalone run using a rejected or needs-work verification response fails and retains gate evidence in its canonical and artifact stores.
- A task lifecycle fixture with a matching acceptance criterion and passing verification evidence may be accepted by the deterministic director after terminal projection.
- A rejected gate with remaining attempt budget requests recovery from verification; the next dispatch consumes the request and passes a distinct attempt and session. A repeated dispatch of the succeeded task is refused without changing the ledger.
- The guard fixture exercises a gate-visit limit and persists a stop decision linked to guard evidence; it does not exercise repeated findings.
- Capacity wait creates no attempt, reserved session, or lease.

The bundled standalone success mock covers only validation and successful gate output. `TaskRuntimeExampleTests` checks both standalone non-accepted responses and the task ledger, decision, and reservation outcomes.
