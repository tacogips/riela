Review the current worktree implementation against the full requested journey and fix defects you find.

Prove each point from source and tests:
- A complex assistant task cannot satisfy the system policy by authoring a workflow without running it.
- Private definitions are absent from project/user/profile workflow discovery and are cleaned up; wording does not overclaim same-user OS isolation.
- Session persistence uses the same store observed by Riela Web.
- The global run endpoint and deep link work without an instance and without reading the workflow definition.
- Existing instance-bound run URLs still work.
- Folder-path creation rejects unsafe, conflicting, or reparenting cases and leaves a correctly tagged run notebook.
- Input, Work log, Response, session ID, and Web link are all represented in the assistant contract and docs.
- No separate view/run scope was added unless evidence proves it necessary.

Fix high- and medium-severity findings within scope. Return concise JSON with decision, findings, fixes, and remaining risks.
