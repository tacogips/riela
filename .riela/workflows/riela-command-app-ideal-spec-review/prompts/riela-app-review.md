Review the requested ideal specification from the RielaApp user's point of view.

Use the intake output and the command-review output. Inspect local repository evidence. Focus on what the app user sees and can act on without reading CLI documentation:
- List packages/workflows and distinguish ready, disabled, missing-env, update-available, and error states.
- Enable disabled rielapkg and directory packages.
- Select, validate, and remember environment configuration without exposing secret values.
- See required environment variable names, descriptions, source package/workflow, and missing/present readiness.
- Import or update packages with clear results.
- Start, stop, inspect, and troubleshoot workflow serving from the app.

Evaluate whether the current or proposed ideal specification answers:
- What is visible in the workflow/package list before the user clicks anything?
- Which actions are primary, secondary, disabled, or hidden for each state?
- How does the app make CLI/package metadata understandable without leaking secrets?
- How does the app handle project vs user scope, archive packages, directory packages, package disable/enable, and workflow-level env requirements?
- What status text, table columns, dialogs, errors, confirmation flows, and telemetry should exist?
- What app-support tests, UI smoke checks, or manual QA paths prove the behavior?

Return JSON with:
- `surface`: `"riela-app"`.
- `ideal_user_journeys`: ordered app journeys with visible states and actions.
- `gaps`: prioritized gaps, each with severity, evidence, and why it matters to a user.
- `recommended_spec_changes`: concrete changes to add to the ideal spec.
- `implementation_implications`: source areas or tests likely affected.
- `acceptance_criteria`: user-visible criteria for the app surface.
- `residual_risks`: risks not resolved by the proposed spec.
