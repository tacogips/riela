# Expected results

The mock follows the default `page` branch. Its final `value` contains two
items, and `nextCursor` is `mock-next`. The first item's text remains the
literal `A quoted "example" with {{literal}} text`.

For a real reader output, transition labels are evaluated in order:

- `providerRetryable` returns `{ "retryLater": true, "category": ... }` and
  does not loop or retry.
- `providerFailed` returns its failure category and retryable flag.
- `postprocessFailed` reports the structured failure category and retryable
  flag.
- Otherwise `page` returns the shaped posts and `pageInfo.nextToken` as
  `nextCursor`.

First-page input is `{"workflowInput":{"query":"...","cursor":null}}`.
Use the output cursor as `workflowInput.cursor` for the next execution.
