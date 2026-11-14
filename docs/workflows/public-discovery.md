# Public discovery

`riela/public-discovery` version `1` discovers public source URLs using bounded
provider requests. Results have `content_scope: "search-discovery-only"`:
search titles and snippets are candidates, never verified evidence. The node
does not fetch result pages, run a browser, inspect private mail or read a source
cache. Pass only an independently constructed public search query.

```json
{
  "query": "FluidAudio Phonon CoreML",
  "providers": ["hn-algolia", "github-repositories"],
  "max_providers": 2,
  "max_query_variants": 2,
  "identifier_fallback": true,
  "stop_when_sufficient": true,
  "limit": 5,
  "blockedHosts": ["x.com", "twitter.com"]
}
```

Provider choices are `bing-rss`, `duckduckgo-html`, `github-repositories`,
`hn-algolia`, and opt-in `openrouter-exa`. Defaults are Bing then DuckDuckGo.
`max_providers` and `max_query_variants` are 1–2; query variants default to one.
`limit` defaults to 5 and `max_results` to 10, each 1–10; the lower bounds the
returned results. Queries are nonempty, at most 300 Unicode scalars, without
ASCII control characters. `exact_phrase` defaults false. A second variant uses
one CamelCase identifier when `identifier_fallback` is true, otherwise an exact
phrase. `stop_when_sufficient` defaults false, preserving provider traversal;
when true, enough accepted results prevent later requests. Provider and variant
order is explicit. There is no transport retry; 401/403/429 stop variants for
that provider, allowing an independent later provider.

Each request accepts at most 500,000 bytes with a 25-second timeout clipped to
the node deadline. The theoretical `request_budget` is at most four; returned
`providers` records describe actual observations with finite status, accepted
and rejected counts, source scope and optional HTTP code. Provider errors never
include query, credentials, headers, response bodies or raw exception messages.
Cancellation propagates instead of becoming a provider failure. Missing or
malformed native capability must be surfaced by callers, without HTTP fallback.

RSS is parsed in memory without external entities. DuckDuckGo includes only
result anchors, excludes script/style/template/noscript text and unwraps its
link wrapper exactly once. GitHub includes public repositories only; HN accepts
indexed story URLs or numeric story identifiers. HTTPS result URLs reject
credentials, nonstandard ports, local/internal or nonpublic numeric addresses,
X/Twitter, authored blocked hosts, navigation/search wrappers and ad redirectors.
Tracking query fields and fragments are removed before ordered deduplication.
Titles/snippets are bounded to 500/1,500 Unicode scalars. Result bodies must be
fetched separately through the public-Web reader, whose DNS checks remain
necessary; discovery does not resolve candidate hostnames.

## Optional authenticated Exa discovery

`openrouter-exa` uses the existing OpenRouter web plugin with pinned model
`openai/gpt-4.1-mini`, max_tokens 1,000, engine `exa`, at most five results and
X/Twitter domain exclusions. Only URL citation annotations are returned; model
text, citation titles and excerpts are discarded. Selecting this provider may
incur provider charges; no model/provider choice is made implicitly.

The environment variable name is `credentialEnvironment` (default
`OPENROUTER_API_KEY`); only that name and `ART_LATEST_LLM_API_KEY` are accepted.
Other process environment values cannot be selected as credentials. Its value is read only from the node process environment;
never put tokens in configuration, variables or artifacts. ART supplies its
existing `ART_LATEST_LLM_API_KEY` name. The authenticated native capability fixes
POST URL and host to `https://openrouter.ai/api/v1/chat/completions`, builds the
Bearer header internally, performs public-IP DNS pinning and certificate/peer
validation, disables proxy/netrc and never follows redirects. Callers cannot
replace endpoint, headers or model. It shares low-level transport machinery
with public Web while remaining a separate capability: `riela/public-web` still
accepts only unauthenticated conditional GET headers.

Serialized configuration is capped at 65,536 bytes and the final discovery
result at 256,000 bytes, covering ten maximally bounded URL/title/snippet rows
including JSON escaping. Unknown configuration fields are rejected before IO.

At most 20 distinct blocked hosts, including the mandatory X/Twitter entries,
are accepted. Duplicate defaults do not reduce the custom-host allowance.
