# Expected results

- Validation succeeds with steps `check-login`, `publish`, and `report`.
- A plain mock run exits 5 with status `suspended` and a suspend record because the user must authenticate on a reachable host.
- The task harness refuses takeover without `userReachable`, then accepts `userReachable` and completes from `publish`.
