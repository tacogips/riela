# Expected results

- Validation succeeds with steps `plan`, `apply`, and `report`.
- A plain mock run exits 5 with status `suspended` and a suspend record because `plan` requests a deployment target.
- The task harness records the answer, imports the `plan` history, resumes at `apply` with `handover.answer.option` in its input snapshot, and completes.
