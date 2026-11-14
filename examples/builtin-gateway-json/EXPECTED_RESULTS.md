# Expected results

The credential-free mock run completes all three nodes:

- `accounts.processed` is `[{"id":"fixture-account"}]`.
- `threads.processed` is `[{"id":"fixture-thread-1"},{"id":"fixture-thread-2"}]`.
- The thread response retains `data.threads.pageInfo.endCursor` as
  `mock-gmail-next` for the next workflow execution.
- `draft.processed` is `"fixture-draft"`; the draft role creates a draft and
  does not send it.

For a real first page, provide `workflowInput` with an account ID and a null
cursor, for example `{"accountId":"configured-account","cursor":null}`.
Use the returned `endCursor` as `cursor` on the next run. The draft node runs
once at the end of each workflow execution.
