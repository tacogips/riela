# ssg2-02 fragment hydration progress

Status: implementation complete; formal review pending. Accepted dependency ssg2-01 is present in dispatch; design §3.3–3.4 and plan were checked. Shared tree is moving; no Git state changed. Earlier status and attempts below are historical.

Partial work: added recursive fragment expansion, root-scoped batched fetch and SHA checks, session and nested assembly integration, and initial core tests. The CLI parity test and full plan coverage are not yet authored. No behavioral test has passed. A reduced execution whose corruption removes its marker needs further fail-closed analysis and regression coverage before acceptance.

Pre-edit SHA256: encoder 4348b91148e91cf2c44eb00ded23532da389243981bcbdf0b0d987b4306bf03b; session family 2d5818ed3af5283b1e66658c77a868d85beb5fe2d7e0582ab9102d0a98af8b14; nested 28ae20ca2f6ad54bea81f4bda5c24c66e91512cefe6d6632e1c5ca96102fbb7c. New test absent.

Post-edit SHA256: encoder bc80798e24318b034a2cb02d033f4d809464173e12cd971cda8d0533c6faa299; session family 0073a733e59a80f0009d03e1ae6cdb648853d68233d5359384c6d016482e5788; nested 79c8c41aa844a9ed520123afc09ea0d85150eed4d2294f895dde3fee18fe527d; core test 3cf0a0a2849c576fc734cad949d352cbe5fbcbf54e4374d2c87851ffe1bdc4a7.

Build attempt: `HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-02-fragment-hydration/build-attempt-01.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-02-fragment-hydration/build-attempt-01.log; exit $s'` exited 1: sibling-owned `Sources/RielaCLI/StorageMaintenanceConversion.swift:141` has a throwing expression without required `try`. Repair by its owner and rerun all gates on final source. This attempt preceded a small lint fix and test fixture type correction.

Changed-file strict lint: `arch -arm64 /bin/zsh -lc 'set -o pipefail; changed_swift_manifest=tmp/ssg2/ssg2-02-fragment-hydration/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi 2>&1 | tee tmp/ssg2/ssg2-02-fragment-hydration/lint-final.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-02-fragment-hydration/lint-final.log; exit $s'` exited 0. Earlier lint-attempt-01.log exited 1 and was fixed.

Remaining: fix sibling compile blocker; complete nested, legacy, execution corruption, web and CLI parity tests and any needed implementation fixes; run plan build/test/lint gates and acceptance checks. Formal review is downstream.

## Continuation

The sibling compile failure no longer reproduces. Expansion now only traverses `inputSnapshot`, preserving reference-shaped user data in other execution fields. Added reduced nested reservation and terminal snapshot round trips and a literal-reference regression. Current SHA256: encoder `4e76a04fe5010aec27f512966a293e0083b3c7a9135c1601cf4666f10ee517eb`; session family `0073a733e59a80f0009d03e1ae6cdb648853d68233d5359384c6d016482e5788`; nested `79c8c41aa844a9ed520123afc09ea0d85150eed4d2294f895dde3fee18fe527d`; core tests `02f585f25740b481bb779a9dab1da178d3784c10c0d396cade66b6d298623dd9`.

On the moving shared tree, `build-current.log` exited 0, `test-current.log` exited 0 with 70 tests and zero failures, and `lint-current.log` exited 0 using `changed-swift-current.nul`. The required CLI parity test class does not exist yet, so these results do not satisfy the plan. Remaining: full CLI parity, legacy and web assertions, shared-fragment assertion, marker-removal corruption analysis, and final source-matched verification. Formal review and commit remain downstream.

## Continuation 1: implementation complete

Added running and completed reduced/canonical/legacy CLI status, export, logs and progress parity, core and web reads, nested reservations, legacy inline and marker text, shared fragment and multi-level expansion coverage. `build-cont1.log`, `test-cont1-final.log`, `lint-plan-cont1-final.log`, `lint-cont1-final.log`, and `acceptance-cont1.log` exited 0; the test suite ran 72 tests with zero failures, including both required classes and writer tests. These ran on the moving shared tree. The changed-file lint manifest is `changed-swift-cont1.nul`.

Final SHA256: encoder `4e76a04fe5010aec27f512966a293e0083b3c7a9135c1601cf4666f10ee517eb`; session family `0073a733e59a80f0009d03e1ae6cdb648853d68233d5359384c6d016482e5788`; nested `79c8c41aa844a9ed520123afc09ea0d85150eed4d2294f895dde3fee18fe527d`; core test `3c576ff48091837d188b9b70a8e40102f02fa39eb8fa67ec87f93e3aa6560603`; CLI test `0e8d4c98d48fd400cae73c25b889811621aabbb9cb052264679a2c80a9726b45`.

The specified no-marker fast path does not verify a parent payload whose corruption removed its marker; fragment corruption is verified as required. Formal reviews and final commit remain downstream.
