# Task

Perform final verification of the terminal Codex tool-child stall recovery implementation. You may make narrowly scoped fixes for verification failures, but do not broaden scope or modify unrelated dirty work.

Read `.codex/skills/swift-coding-agent/SKILL.md` completely. Use only `tmp/codex-tool-reap-recovery/` for scratch/logs. Do not commit or push.

When sibling `../riela-packages` contains affected package changes, also verify package digests, workflow validation, repository `task check`, diff checks, and absence of scratch files outside that repository's own `tmp/`. If no packaged contract required a change, report that explicitly.

Verify `impl-plans/REMAINING-WORK-HANDOVER.md` against a fresh machine-generated inventory of active plans, unchecked checkboxes, incomplete status markers, dirty files, and affected package payloads. Confirm the document contains its MECE self-review evidence, has zero orphan remaining tasks, zero duplicate primary ownership assignments, and a dependency-ordered continuation path. Fix documentation discrepancies before returning.

Verify requirement by requirement against both:

- `design-docs/specs/design-codex-unified-exec-stall-followup.md`
- `impl-plans/active/codex-unified-exec-stall-followup.md`

Required evidence:

- deterministic focused unit/adversarial tests pass
- macOS integration fixture passes locally; Linux-specific logic has deterministic coverage and portable compile guards
- full `swift test` passes on the exact final tree
- strict SwiftLint passes for every changed Swift file
- no changed Swift file exceeds 1000 lines
- CLI help, policy Codable defaults, GraphQL/library parity, session inspection, redaction, cancellation, and idempotency assertions pass
- `git diff --check` passes
- no process fixture, direct agent child, monitor, socket, or scratch file exists outside the allowed tmp directory after verification
- every affected `../riela-packages` payload is synchronized, digest-refreshed, and registry-validated
- the remaining-work handover has zero inventory orphans and zero duplicate primary workstream ownership after final self-review

Update plan/design/progress/inventory status only from evidence. If any checklist item is not complete, leave it unchecked and return `status: blocked` with exact evidence; otherwise mark the Section 5 checklist complete and return `status: completed`. Return one concise JSON object containing status, requirement matrix, commands/results, changed files, and residual risks.
