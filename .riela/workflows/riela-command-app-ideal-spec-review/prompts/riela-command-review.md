Review the requested ideal specification from the `riela` command user's point of view.

Use the intake output and inspect local repository evidence. Focus on the workflows a command user actually performs:
- Discover installed and available packages/workflows.
- Understand package status, disabled/enabled state, update availability, required environment variables, and missing configuration.
- Install, update, disable, enable, remove, validate, inspect, and run package-provided workflows.
- Recover from errors with clear next commands.
- Use machine-readable output where automation needs it.

Evaluate whether the current or proposed ideal specification answers:
- What is the user's first screen or first command?
- What can the user safely do without understanding internal manifest details?
- How does the command expose package metadata, required env vars, disabled state, and readiness?
- How are project scope, user scope, rielapkg archive installs, directory package installs, and workflow package usage represented consistently?
- What are the exact command names, flags, status labels, exit behavior, and JSON fields a user can rely on?
- What validation, tests, or examples prove the behavior?

Return JSON with:
- `surface`: `"riela-command"`.
- `ideal_user_journeys`: ordered journeys with the commands a user should run.
- `gaps`: prioritized gaps, each with severity, evidence, and why it matters to a user.
- `recommended_spec_changes`: concrete changes to add to the ideal spec.
- `implementation_implications`: source areas or tests likely affected.
- `acceptance_criteria`: user-visible criteria for the command surface.
- `residual_risks`: risks not resolved by the proposed spec.
