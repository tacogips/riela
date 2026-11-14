# sac-01-control-contract progress

- Mode: issue-resolution; issue: none, manager dispatch comm-019851.
- Accepted design §§3.3, 3.5 and 3.10 checked; no dependencies.
- Before edits: source, tests and this progress file absent (no pre-edit SHA256).
- Added public operation/result/ports and wire contract, strict request and response key validation, limits, and focused tests. Service, socket and integration remain downstream.
- Per-edit intentions and snapshots: `tmp/serverless-app-control/sac-01-control-contract/intent-*.txt` and `pre-*`/`post-*` snapshots.
- Verification and final checks will be recorded below after the shared SwiftPM build completes.

- Final source SHA256: `fada1944508524cf5c821867aea790292621234f1c19d1bcdbb97469cd8ad3a9` (contract), `4310d8c98cc1dcf9373629a5a5acd35e4dcb35c23cb1ba772fafa134b2baa54c` (tests). Active plan pre/post SHA256 recorded in evidence `pre-plan.sha256` and `final-hashes.txt`.
- Symbol inventory: `rg -n '^public (enum|struct|protocol) RielaApp' Sources/RielaAppSupport/RielaAppControlContract.swift` lists all 12 required symbols; see `symbols.log`.
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests'`: exit 0, `build-final.log`. Initial build exit 1 (`build.log`) identified missing `try` in two test assertions; corrected and rerun.
- `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter RielaAppControlContractTests'`: exit 0, 4 tests, 0 failures, `test.log`.
- Scoped plan lint and strict changed-file manifest lint: exit 0, `lint-final.log` and `lint-strict-final2.log`.
- Shared working tree includes sibling plan changes; this plan did not modify those files. Verification ran on the moving shared tree; serial integration verification remains downstream.
