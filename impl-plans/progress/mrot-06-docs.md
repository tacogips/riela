# mrot-06-docs progress

Implementation: documented the run overlap flag, refusal and compatibility behavior, cron policies, and known limits. Added the linked README sentence; the reload error table is unchanged. Accepted design sections 3.2–3.6 and 5 match the assigned plan; no dependencies are required.

Verification on the shared tree: `git diff --check -- docs/app-instance-control.md README.md` exit 0; `grep -n allow-overlap docs/app-instance-control.md` exit 0 with two matching lines; `grep -n instance_busy docs/app-instance-control.md` exit 0. Complete logs and exit files are under `tmp/manual-overlap-terminal-reserve/mrot-06-docs/`. These are documentation checks, with no tests run.

Fresh-read edit hashes (with snapshots and intentions alongside the logs):
- 01-docs-hashes.txt: before 4628ca295767c4d9ee6b77a11ef5e88266264cc65cc2e143ebacca1396f15215; after 7ce0ae0686316ca61bb7691024ae94713402fabe948f6991f67a6f099ff14b97
- 02-readme-hashes.txt: before 3467e4c5e5368711fb09a9f74e61cda8e102b268410f1974312a58d241713824; after 9039a48b8de9fb173d459e8884c8ae324e36ad1a0800b6f30f1c85e201ffcaa8
- 03-plan-hashes.txt: before 32b764fa30767db9f373d50cba07b91e008e454ef47049c9dc0cde7d9f540066; after fddd60bcf05042ea31ac90f8bbc03896e256cbb16b212a6b0cb4fd88ea2a711b

Formal review, integration verification, commit, and push are downstream workflow steps.
