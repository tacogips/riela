Review the synthesized ideal specification as a critical user advocate and improve it.

Check for these failure modes:
- The spec describes implementation internals but not user-visible behavior.
- The command and app experiences diverge in vocabulary, status labels, or capabilities without explaining why.
- Required environment variable metadata is vague, leaks secret values, or fails to define missing/present readiness.
- Disable/enable behavior is unclear for either rielapkg archives or directory packages.
- Package update, install, import, validation, and run flows are not tied to user actions and expected feedback.
- Acceptance criteria are not testable.
- Error and recovery behavior lacks exact messages, next actions, or exit/status behavior.
- The spec is too optimistic and does not name risks, non-goals, or migration assumptions.

If an output document was updated, edit it again to fix the issues you find. Keep the result concise, concrete, and user-facing. Do not commit or push.

Return JSON with:
- `accepted`: true only if no high or medium user-impact findings remain.
- `findings`: findings fixed or intentionally left, with severity and affected surface.
- `improvements_applied`: concrete changes made to the spec or proposed spec.
- `updated_files`: repository-relative paths changed.
- `final_acceptance_criteria`: command and app acceptance criteria after review.
- `verification`: validation or review checks performed.
- `remaining_risks`: accepted residual risks.
