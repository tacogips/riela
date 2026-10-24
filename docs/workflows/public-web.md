# Public Web builtin

`riela/public-web` version `1` reads a public HTTPS URL without gateway
credentials, browser cookies or environment proxies. It runs in the calling
runtime. For untrusted pages, invoke it inside a private workflow and inspect the
result before exporting it. This node does not publish, acknowledge records or
advance acquisition checkpoints.

```json
{
  "addon": {
    "name": "riela/public-web",
    "version": "1",
    "config": {
      "url": "https://example.com/article",
      "options": {"mode": "auto", "maxTextChars": 20000},
      "blockedHosts": ["x.com", "twitter.com"]
    }
  }
}
```

`action` defaults to `page`. `options` accepts `mode` (`auto`, `http`, `browser`),
`minTextChars` (0–20000, default 400), `waitMs` (0–5000, default 1500), `timeoutMs`
(1000–30000, default 20000), and `maxTextChars` (1–50000, default 20000).
`auto` tries HTTP and uses the optional renderer for short/failed documents within
the same deadline. Blocked destinations and invalid inputs never trigger fallback.
The output has `kind`, `url`, `title`, `text`, `links`, `method`, `fetched_at`,
`content_scope` and nullable `published_at`. HTML extraction prefers article/main
regions and omits hidden/script content. It is not an instruction sanitizer.

`metadataOnly: true` reads only public head title/description/date metadata,
adds nullable `canonical`, and never returns article text or renders a browser.
`linkPattern` is an authored regular expression (at most 512 UTF-8 bytes) on
same-origin URL paths, applied before the discovery link budget. Its pattern is
configuration, never page-supplied code. `includeRaw: true` returns
`raw_body_base64` on an HTTP result for a private domain-specific parser. It cannot
be combined with a browser result.

`action: "response"` returns `status`, `headers`, `bodyBase64`, `url` and
`notModified`. It accepts `headers` containing only `If-None-Match` and
`If-Modified-Since`, `maximumBytes` (1–2000000, default 2000000), and `timeoutMs`
(1–120000, default 25000). A 304 result has an empty body. Other successful
responses must be 200. The node makes one attempt per hop; the source workflow
owns retry/checkpoint policy, so an unavailable article does not stall its peers.

`action: "parse"` accepts `bodyBase64` (decoded maximum 2 MB) plus page `options`
and `metadataOnly`, and extracts the document without DNS or a network request.
The URL still passes syntax/literal-address policy. All actions support common
JSON postprocessing. CLI data references remain literal, including `{{...}}`
inside the downloaded document.

HTTP uses native libcurl with TLS verification, all-answer public-address checks,
DNS pinning, peer verification before connecting, at most three manually checked
redirects, a 64 KB header budget and a 2 MB page body budget. Bodies are bounded
while reading, including decompression; oversized responses fail. Private,
loopback, link-local, shared, documentation, multicast and transition ranges are
rejected. The policy deliberately allows only allocated IPv6 global unicast
outside reserved protocol/documentation/transition prefixes. Blocking libc DNS
runs in at most eight owned resolver tasks; callers stop waiting on deadline or
cancellation, and late results are freed by the remaining owner.

The optional renderer is a bundled Riela-owned Python/Playwright bridge. Authors
provide JSON, not scripts. It requires Python with Playwright/Chromium installed;
HTTP and parse actions do not. `RIELA_PUBLIC_WEB_PYTHON` may select an absolute
interpreter path; defaults are `/usr/local/bin/python3` and `/usr/bin/python3`.
Browser binaries are expected under `/opt/playwright`. Chromium sandboxing is
required; an environment that cannot enable it fails rather than using
`--no-sandbox`. The child inherits no
credential/proxy environment, runs with `-I -B`, and has an owned process deadline.
Its context is offline with service workers, downloads and WebSockets blocked;
every allowed request is fulfilled by pinned public HTTPS. It drops image/media/
font requests, restricts methods, strips auth/cookie/referrer headers, caps POST
bodies at 64 KB and enforces 100-request/20 MB totals. Install the optional browser
runtime explicitly in the private guest image; no fallback installation occurs.

Build dependencies are libcurl and libxml2 development headers/libraries. Shipped
Linux build/container recipes install them; release packaging must retain the
RielaCLI resource bundle alongside the executable.
