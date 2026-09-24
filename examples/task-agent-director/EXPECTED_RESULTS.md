# Expected results

- Workflow validation succeeds with one worker step, director, and no transitions or recursive child workflow.
- The bundled mock workflow run completes and returns one recommendation with kind accept.
- A task lifecycle fixture records the child session, attempt, and cost exactly once, then applies an allowed decision only through the shared causal and completion checks.
- Invalid, forbidden, failed, or budget-blocked child output leaves the task needing a human decision with durable evidence. It never launches a second director.

The standalone workflow run covers only the first two points. `TaskRuntimeExampleTests` checks parent task outcomes and durable replay invariants through the real store and runner.
