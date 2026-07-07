# Read-only repository inspection

Inspect the current working directory without modifying anything.

This node runs with `agentSandbox: read-only` and
`RIELA_SANDBOX_SEATBELT=auto`, so on macOS the agent process is
launched under a Seatbelt profile that denies filesystem writes
outside the agent's own state and temp directories. Any attempt to
write into the repository fails at the OS level.

Report:

- the working directory path
- up to five top-level entries you can read
- whether you attempted any write (you must not)

Return concise JSON only:

```json
{
  "workingDirectory": "...",
  "topLevelEntries": ["..."],
  "writesAttempted": false,
  "summary": "..."
}
```
