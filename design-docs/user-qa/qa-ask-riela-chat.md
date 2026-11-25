# Ask Riela: default decisions open to revisit

## Issue reference

No GitHub issue. workflowInput of
`fable-sol-design-and-implement-review-loop-session-4`: "Ask Riela:
runtime-grounded AI agent chat unified with workflow authoring". Design:
`design-docs/specs/design-ask-riela-chat.md`.

## Status

None of these block implementation. Each question already has a decided
default in the design. Implementation follows the default unless the user
changes it.

## Questions

1. **How are tools offered to API backends and cursor?**
   Default: a host-run tool loop (`rounds` transport). The pinned
   agent-gateway accepts no client tool definitions for API vendors and passes
   stdio MCP servers only to codex and claude, so native tool calling would
   need a pin change. codex and claude use the stdio MCP server. Setting
   `RIELA_ASK_TOOL_TRANSPORT=rounds` forces the host loop everywhere.
   (Design §5.3.)
2. **What is the CLI conversation form?**
   Default: `riela ask "<message>"` starts a conversation and prints its id;
   `riela ask --conversation <id> "<message>"` continues it; `riela ask
   list|show|cancel|confirm|dismiss|remove` manage it. No interactive prompt
   loop. (Design §13.)
3. **Which model is the default for a vendor with no stored choice?**
   Default: the first manifest entry, which becomes `gpt-6.2-sol` for
   codex/OpenAI and `claude-sonnet-5-5` for claude/Anthropic. A stored choice
   is never changed. (Design §9.)
4. **Does the RielaApp native mini chat become the Ask chat?**
   Default: no. It keeps its behaviour (an agent that authors and runs a
   private workflow) and its stored transcript. RielaApp users get Ask Riela
   through the web console the app serves. (Design §2, §9.)
5. **Does the workflow graph still change while the model is working?**
   Default: no. A generated workflow is a proposal card; the editor draft
   changes when the user confirms it. (Design §11.)
6. **Is live model listing for API vendors kept in assistant settings?**
   Default: no. Settings show the Bots catalog (bundled manifest, models the
   backend reported, custom models). An unlisted model can still be used and
   is reported as `model_unknown`. (Design §9.)
7. **What scope does a paired client need to chat on a remote?**
   Default: `operate`, because a chat turn uses that server's model
   credentials and may lead to confirmed actions. `read` can list and read
   conversations. (Design §12.)
8. **How long does a proposed action stay confirmable?**
   Default: 24 hours. (Design §7.2.)
