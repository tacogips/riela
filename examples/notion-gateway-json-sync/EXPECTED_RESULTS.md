# Expected results

The credential-free mock completes `query`, `prepare`, and `create`:

- The raw search response is a native Notion list with two native page objects.
  Each page stores its title under `properties.title.title[0].plain_text`.
  Finite postprocess maps that path with the `Untitled` default, takes up to 10,
  and selects the first title, so `query.processed` is `"Mock page to sync"`.
- A result without the standard `title` property maps to `"Untitled"` instead
  of passing a null title to `createPage`.
- `query.data.searchPages.has_more` is `true` and
  `query.data.searchPages.next_cursor` is `mock-notion-next`; the raw gateway
  response keeps the cursor next to `processed`.
- `create.processed` is `"fixture-created-page"`.

For a real run, pass the current cursor as `workflowInput.cursor` and use the
returned `next_cursor` for the next execution. The `createPage` write runs once
per workflow execution. A postprocess failure does not trigger an implicit
write resend.
