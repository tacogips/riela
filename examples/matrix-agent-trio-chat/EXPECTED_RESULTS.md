# Expected Results

- The workflow validates as a step-addressed Matrix chat bundle.
- The app icon assets are stored with the workflow:
  - `assets/icons/yui-codex.png`
  - `assets/icons/mika-claude.png`
  - `assets/icons/rina-cursor.png`
- `route-message` uses `riela/chat-persona-router` to select exactly one initial responder without a provider-specific routing prompt.
- Messages with no named bot route to Yui Codex.
- Messages that call Mika Trend route only to Mika.
- Messages that call Rina Cursor route only to Rina.
- If the selected persona is asked to hear another named persona too, that node
  sets a handoff flag such as `handoff_mika`, allowing a follow-up node response.
- The selected persona's reply is sent through its `send-*-reply` step before
  any handoff transition runs, so multi-bot discussions produce visible Yui,
  Mika, and Rina chat messages in workflow order.
- Handoff replies include a visible provider-neutral mention such as `@Mika` or
  `@Rina` plus a concrete question, so autonomous discussion is readable in the
  chat instead of being only an internal route.
- Requests such as `しばらく自然に雑談して` keep the trio in bounded autonomous
  conversation for up to six persona turns across Yui, Mika, and Rina, then clear
  all handoff flags and close the final reply so the workflow stops without a
  dangling mention or runaway loop.
- Each persona reads only its own recent records from the declared
  `persona-chat-memory` memory database before replying, using
  `workflowInput.memoryRoot`, `RIELA_MEMORY_ROOT`, or the default Riela memory
  root.
- Each persona can return `memoryEntries` for explicit remember requests,
  corrections, durable preferences, important events, or refreshed old memories;
  the workflow writes them through `riela/chat-persona-memory-write` with
  persona-scoped tags.
- Matrix replies are sent through `riela/chat-reply-worker` to the same
  conversation and thread from the normalized chat event.
- Matrix event source fixtures validate with `matrix-agent-trio-to-workflow`.
- Text-compatible Matrix attachments can be downloaded into deterministic
  descriptors when the Matrix source attachment settings allow the MIME type.
- Accepted messages can be persisted as bounded chat history and reloaded after
  an event runner restart when the same event data root is reused.
