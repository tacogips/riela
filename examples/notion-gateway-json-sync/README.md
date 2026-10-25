# Notion JSON search and page creation

This example reads one page of accessible Notion pages with
`searchPages(startCursor: ...)`, shapes native Notion page objects with JSON
postprocess, and creates one child page with the first result's title. The
title is read from `properties.title.title[0].plain_text`; pages without that
property use the deterministic default `Untitled`. It uses the linked
Notion reader and writer roles and has no command, script, Python, shell, jq,
or credentials in its mock scenario.

Validate and run the mock from the repository root:

```sh
riela workflow validate notion-gateway-json-sync --workflow-definition-dir examples
riela workflow run notion-gateway-json-sync --workflow-definition-dir examples \
  --mock-scenario examples/notion-gateway-json-sync/mock-scenario.json --output json
```

For a real run, set `NOTION_API_KEY`, replace the fixture parent ID in the
`prepare` node with a parent page connected to the integration, and provide
`workflowInput.query` and `workflowInput.cursor` to the query operation. Use
null for the first cursor. The query node retains native `has_more` and
`next_cursor` alongside `processed`; pass `next_cursor` as the next run's
cursor. The writer creates one page per execution. Its single write is not
resent if postprocess fails.

See [expected results](EXPECTED_RESULTS.md) and the
[gateway JSON reference](../../docs/builtin-gateway-json.md).
