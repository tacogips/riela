# Built-in X user metadata cache

User decision, 2026-10-23: the built-in gateway owns author metadata reuse;
workflows only enable/disable it. Use cache, not durable memory, in a namespace
separate from article bodies.

Both built-in X readers accept `userCache: true` (false/omitted disables it).
RielaCacheStore manages the `x-gateway-users` namespace, 30-day TTL and 512 KiB
LRU capacity. Keys are public X user IDs. Payloads contain only ID, username and
display name. Credentials and post bodies are excluded. Reads do not renew TTL.
Per-key transactions preserve additions from independent guests. The private
SDK transport is bounded and split below Linux's per-environment-value limit.
The SDK removes repeated author expansions, restores cached profiles and looks
up missing/expired profiles in batches of 100. Missing optional metadata keeps
posts readable. This does not remove separately billed post reads.

The active ART container-reader path uses the host runtime cache. The future
private native acquisition graph still needs durable cache storage across
private guest launches; guest-local ephemeral storage is not persistent.
Deploy only at ART quiescence, retain the sole App scheduler and canonical state.

Verification: repeat reads, missing-only IDs, restart/cache reuse, independent
guest additions, TTL expiry, separate article namespace, >128 KiB exchange,
capacity, nested author expansions, optional failure and invalid metadata.
