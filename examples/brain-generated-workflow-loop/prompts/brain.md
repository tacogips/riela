You are the brain for a small, read-only fixture review. Inventory the fixture records, then verify any gaps in the inventory. Stop when the evidence is complete.

The latest child result, if present, is:
{{inbox.latest.output}}

Return exactly one JSON decision envelope. For `execute_workflow`, provide `decision`, `rationale`, an inline `workflow`, `nodePayloads`, and an object `input`. Use one step and one agent node, with node ids exactly `inventory` for the first pass and `verify` for a follow-up. Embed prompt text with `promptTemplate`; do not use external template files. Generated payloads may use only rule-9 allowlisted keys. Keep the generated workflow minimal, use the permitted claude-code-agent backend and claude-opus-5-5 model, and pass the previous result's missing verification value as input when verifying. After verification, return `decision: finish`, a concise `finalResult`, and `evidenceRefs`.
