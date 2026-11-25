# Bots: default decisions open to revisit

## Issue reference

No GitHub issue. workflowInput of
`fable-sol-design-and-implement-review-loop-session-1`: "First-class Bots
feature". Design: `design-docs/specs/design-bots-overview.md`.

## Status

None of these block implementation. Each question already has a decided
default in the design. Implementation follows the default unless the user
changes it.

## Questions

1. **What is the client command for paired servers called?**
   Default: `riela remote add|list|show|remove|use`, with `--remote <name>` and
   `--all-remotes` selectors. `riela environment` already exists and means
   "workflow instance environment" (`status`, `reload`), so the name requested
   in the brief would collide. (Design §11.4.)
2. **How long does a bot wait for a permission answer?**
   Default: 300 seconds for bot-linked sessions (`permissionWaitMs`, per bot,
   0 to 3,600,000), cut to the step deadline; 0 for sessions with no bot, which
   keeps today's immediate decline. Every timeout declines. (Design §6.6.)
3. **Is look-around on by default?**
   Default: off. Memory upkeep defaults to nightly, as in the brief. Look-around
   starts an agent turn on a schedule, so it is opt-in per bot. (Design §10.2.)
4. **What scope does a pairing code grant by default?**
   Default: `operate` (read, start and answer; no pairing, API-key,
   configuration or provider changes and no bot removal). API keys issued
   before this change keep full access. (Design §11.2.)
5. **Is plain HTTP allowed for pairing?**
   Default: only for a literal private-range IP address (LAN, CGNAT/VPN ranges,
   IPv6 unique-local and link-local). Any host name or public address needs
   `https`. Loopback and wildcard addresses are always refused. (Design §11.2.)
6. **Do bot defaults override workflow nodes?**
   Default: no. A bot's default backend and model are used by its own jobs
   (memory upkeep, look-around) and offered as defaults in clients. Workflow
   nodes keep their own settings. (Design §5.1.)
7. **How are requests handled while a paired server is unreachable?**
   Default: they fail with `remote_unreachable`; the last known overview is
   shown as disconnected with its timestamp. Requests are not queued. (Design
   §2, §11.5.)
8. **How much activity and history is kept?**
   Default: 2,000 activity events per session (8 KiB each), 20 closed items per
   bot on the board, auto-settle after 7 days without activity, 500 memory
   entries of at most 4,000 bytes per bot, 16,000 bytes of memory per prompt.
   (Design §5.3, §6.4, §8.3, §9.)
