# Node Input Filters

## Summary

Riela workflow nodes can declare `inputFilters` on the node registry entry. When
present, the runner evaluates the filters before starting the node. At least one
filter must pass for the node to run. Multiple filters are OR conditions.

The first supported filter kind is `telegram`. Its expressions run in
JavaScriptCore through the reusable `RielaJavaScript` package. Filter parse or
evaluation errors are logged and treated as non-matches; they do not fail the
workflow.

## Workflow JSON

```json
{
  "id": "mika-claude-sdk",
  "inputFilters": [
    {
      "kind": "telegram",
      "language": "javascript",
      "expression": "/(^|\\W)(mika|claude)(\\W|$)/i.test(telegram.message.text)"
    }
  ],
  "addon": {
    "name": "riela/claude-sdk-worker",
    "version": "1"
  }
}
```

## Runtime Behavior

- No `inputFilters`: existing behavior is unchanged.
- One or more filters: evaluate in declaration order.
- Any passing filter: start the node normally.
- No passing filters: record a `skipped` step execution and follow the first
  transition whose label matches the skip context. Unlabelled transitions match.
- Terminal skipped node: complete the workflow without root output.
- Filter parse/evaluation error: log the issue and treat that filter as false.

The skip context exposes `input_filter_skipped: true` in `when` and
`inputFilterSkipped: true` in payload for transition labels that need to branch
on skip behavior.

## JavaScript Context

`telegram` filters expose:

- `telegram.message.text`
- `telegram.message.attachments`
- `telegram.message.imagePaths`
- `telegram.message.attachmentText`
- `telegram.actor`
- `telegram.conversation`
- `telegram.chat`
- `telegram.input`
- `event`
- `workflowInput`
- `input`

The parser accepts normalized event runtime variables emitted by event sources:
`event.provider == "telegram"` or `event.input.provider == "telegram"`.

## Extension Points

`RielaJavaScript` owns JavaScriptCore evaluation and has no RielaCore dependency.
RielaCore owns filter model, validation, and runner gating. New event-source
filter kinds should add a parser that converts normalized event runtime
variables into a filter-specific JavaScript root object, then register that kind
in `WorkflowInputFilterEvaluator`.
