Implement the accepted plan for `workflowInput` in the current worktree.

Required behavior:
1. Make the RielaApp assistant policy testable and explicit. For non-trivial tasks it must create, validate, and run a dedicated workflow in the invocation-private root supplied by the app. It must never register/import/expose that definition, and it must remove or allow the app to remove the private definition after the invocation.
2. Supply the assistant the active profile's private workflow root, shared `RIELA_SESSION_STORE`, active `RIELA_NOTE_ROOT`, and a Web run-link template. Create private directories owner-only where supported and clean the invocation root after the agent finishes.
3. Add a definition-independent Riela Web run-detail API backed by persisted session data, plus a stable hash deep link that restores the run-detail view on page load. Preserve existing instance-bound endpoints.
4. Make Riela Note support creating a notebook into a hierarchical folder path from the CLI, with collision-safe parent/class validation. The assistant policy must specify one run notebook with Input, Work log, and Response notes; the Response contains the Web deep link.
5. Update README/help for this user journey and clearly state that agent privacy is Riela registry/discovery/reuse isolation, not a security boundary between arbitrary processes running as the same OS account.
6. Add focused Swift and Web regression tests for policy text/environment/root cleanup, definition-independent run detail, deep-link parsing, and notebook folder placement.

Use maintainable boundaries, preserve unrelated dirty worktree changes, do not commit or push, and keep temporary files in `tmp/`. Run the narrowest useful tests while implementing. Return concise JSON with changed files and verification evidence.
