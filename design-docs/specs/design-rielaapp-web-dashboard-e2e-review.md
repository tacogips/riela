# RielaApp Web Dashboard E2E Review

## Status and evidence

This document records the accepted current-pass scope authored by the completed Fable 5 `riela-app-review` step in `riela-command-app-ideal-spec-review-session-1`. The later synthesis step failed in its adapter after the review output was persisted; it did not invalidate that output.

The authoritative observations are `tmp/web-dashboard-e2e/e2e-result.json`, its six screenshots, and the current Web SPA and RielaApp HTTP API. The original browser run appeared successful while recording three console errors and two important 404 responses: an execution request with an empty instance id and an execution request with a correctly percent-encoded composite id.

## Accepted current-pass outcomes

The current pass MUST:

- Keep `encodeURIComponent` at the client boundary and percent-decode each instance-id path segment exactly once in the Swift API before matching. Apply the rule uniformly to instance detail, configuration, and executions. Invalid encoding and double-encoded identities do not match.
- Suppress the Run logs execution resource until a non-empty instance is selected. The initial screen says “Choose an instance” and makes no `/instances//executions` request.
- Never return plaintext inline environment values from instance GET responses. Return names with masked/set metadata, accept write-only updates, preserve values left blank, and support an explicit clear operation.
- Expose required-environment presence from the existing candidate requirements and effective environment calculation. Instance cards show missing requirements before selection; details show names, descriptions, source, and present/missing only.
- Render distinct running, starting, reloading, stopping, stopped, failed, and needs-source states, together with enabled-at-launch and active state. Lifecycle stays native-app-only in this pass and the web UI says so.
- Give Instances, Run logs, Workflows, and Settings visible loading, empty, and error states. Every mutation reports success or failure; revision conflicts provide a Refresh recovery action.
- Render executions as status-labelled session rows, including diagnostics and the latest-100 truncation notice, rather than raw JSON dumps.
- Label discovered workflows with scope and directory/package origin when current source evidence supports it. State plainly that package import, update, and removal remain native-app/CLI operations.
- Warn and require confirmation before a dashboard port change makes the current page unreachable.
- Remain usable at narrow widths, preserve visible keyboard focus, expose selected navigation state, associate labels and controls, announce asynchronous status, and respect reduced-motion preferences.

## HTTP and client contracts

Instance identities are opaque strings. A route has exactly one encoded path segment for the identity; the server performs one strict percent-decoding pass and compares the resulting string with the canonical identity. The response uses the shipped error envelope `{ error: { code, message }, revision }`.

An instance returns masked inline environment entries shaped as `{ name, isSet, masked }` and required environment entries shaped as `{ name, description, required, secret, source, present }`. Configuration writes send `environmentVariableUpdates` and `environmentVariablesToClear`; omitted or empty write-only values do not replace stored values.

Execution items declare `sessionId`, `workflowId`, `status`, `currentStepId`, `activeStepIds`, and `updatedAt`. The response also declares `diagnostics` and `truncated`, including on the no-history/error-to-load-history path.

The existing global revision is retained. A 409 is expected under cross-view or cross-surface edits, so every mutation surface provides the same changed-elsewhere recovery rather than silently failing.

## Deterministic acceptance

- Swift route tests drive `webAPIResponse` with a composite identity containing `:` and `/` and cover detail, configuration, executions, invalid/double encoding, CSRF/router rejection where practical, revision conflict, response shape, and secret redaction.
- Browser E2E uses deterministic mocked API responses and fails on unexpected requests, bad responses, console errors, or page errors. It proves zero empty-id requests, an encoded composite-id request, loading/empty/error visibility, visible mutation failures and 409 recovery, narrow-layout behavior, keyboard focus, semantic status announcements, and absence of a planted secret from response-derived DOM.
- Focused web lint/typecheck/test/build and relevant Swift test/build/lint commands pass, followed by `git diff --check` and the Swift file-size check.

## Explicit deferrals

This pass does not add package search/install/update/remove APIs, instance start/stop/restart endpoints, a new secret-store or secret-schema migration, a native port editor, opaque replacement instance ids, or per-resource revisions. It also does not invent update readiness that current endpoints cannot compute. The response redaction and write-only update shape are limited to closing the proven critical plaintext-secret defect; stored preference data remains unchanged.

## Residual risks

- Composite identities still embed paths and remain fragile across proxies and logs even after exact-once decoding.
- The global revision can create unrelated 409 conflicts; recovery is improved, not eliminated.
- Dashboard-only users still need the native app or CLI for package and lifecycle operations.
- The loopback/CSRF trust model is unchanged, so response redaction remains security-critical.
- Required-environment parity depends on the existing RielaApp candidate/environment calculation remaining the shared source of truth.
