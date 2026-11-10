# Issue 188 Plan 06: User/reference documentation (step deadline, retry, Notion classification, ART settings)

**Status**: Ready
**planId**: issue188-06-docs
**dependsOn**: (none; wave 1, documentation only, written from the accepted design)
**Design Reference**: design-docs/specs/design-step-deadline-and-retry-policy.md (§3, §4.2, §6, §7, §9)
**Issue**: tacogips/riela#188
**Created**: 2026-11-10
**Last Updated**: 2026-11-10

## Intent and context

Acceptance requires reference documentation of the exact semantics and defaults, and of the exact settings ART should use. The design document already exists, so this plan writes the **user-facing** reference under `docs/`, following the style of `docs/workflows/command-result.md`: short intro, JSON example, then rules. It also adds a Notion subsection to `docs/builtin-gateway-json.md`, next to the existing `### Notion publishPage` section (line ~56).

## Non-goals

- No design-doc edits; the design was accepted in Step 3.
- No README or index rewrites.
- No `examples/` fixture; the design declares it out of scope.
- No ART edits.
- Do not claim any CPU or runtime-overhead fix.

## File-level changes

### docs/workflows/step-deadline-and-retry.md (new)

Sections, kept concise:
1. **Purpose.** One paragraph: there is a whole-step deadline and a per-attempt timeout, and an HTTP request timeout inside a gateway is **not** the job deadline.
2. **Fields.** A table covering:
   - `timeoutMs` (per attempt; unchanged; precedence);
   - `deadlineMs` (1…86 400 000; anchored at readyAt = max(input message time, run start), and at fanout dispatch time for a branch entry);
   - `retry.{maxAttempts 1–10 required, initialDelayMs 1000, multiplier 2, maxDelayMs 30000, jitter none|deterministic}`.

   Defaults: when neither field is set, behaviour is unchanged and nothing is retried.
3. **What the deadline covers.** Restate the design §3.1 phase table:
   - active expiry: fanout slot wait (local fanout), projection, attempts, backoff;
   - elapsed accounting: runner work before dispatch, runtime-store writes;
   - the bound is `stepDeadline + 5 s` plus the outcome store write.

   Note that cross-workflow fanout branches are not actively expired while they wait for a slot. They fail at start with `attempts=0`.
4. **When a failure is retried.** Only `isRetryable == true` and `effectOutcome != unknown`. Retry-After raises the delay. A Retry-After above `maxDelayMs` stops the retries. The budget check happens before any sleep. Cancellation stops immediately.
5. **Validation rules.** List of the §6 rules.
6. **Diagnostics.**
   - backend events `riela.step.attempt.finished` and `riela.step.retry.stopped` with their metadata keys;
   - the `[rielaRetry attempts=… stopReason=… elapsedMs=… timeoutKind=… effectOutcome=…]` suffix;
   - the stopReason vocabulary;
   - telemetry log `riela.step.publication.duration`.
7. **Settings for ART save jobs.** Copy design §9 exactly:
   - save step: `timeoutMs` 180000, `deadlineMs` 600000, `retry` {4, 2000, 2, 60000, deterministic}, `failurePolicy` `fail` and never `advisory`;
   - publish fanout: `collect-partial`;
   - json-route: `deadlineMs` 120000;
   - the overlap policy stays as it is.

   Also state the retention boundary (runtime evidence only; the cross-run backlog belongs to ART) and that `effectOutcome=unknown` items need reconciliation by ART or an operator.
8. **Not covered.** No automatic Notion reconciliation, no idempotency keys, no CPU fix, no retry on agent, stdio or placement steps, and resume semantics are unchanged.

### docs/builtin-gateway-json.md

Add `### Notion failure classification (step retry)` directly after the existing `### Notion publishPage` subsection. It should contain:
- the ordered write-precedence list (design §4.2 rules 1–5);
- the read rules;
- the publishPage taint rule and the narrowed `ensurePagePath` exemption.

State that the notion-gateway does not retry internally, so the number of gateway invocations equals `retry.maxAttempts`. Do not edit any other section.

## Invariants

- Numbers, field names, event names and stop reasons match the design and the plan 01 pinned names exactly: `deadlineMs`, `retry`, `maxAttempts`, `initialDelayMs`, `multiplier`, `maxDelayMs`, `jitter`, `non-retryable`, `outcome-unknown`, `retry-exhausted`, `deadline-exhausted`, `step-deadline`, `retry-after-exceeds-max-delay`, `cancelled`, `succeeded`.
- English only. No trailing whitespace.

## Verification (each must exit 0)

1. `mkdir -p tmp/issue-188 && zsh -c 'git diff --check -- docs/builtin-gateway-json.md 2>&1 | tee tmp/issue-188/p06-diffcheck.log; exit ${pipestatus[1]}'`
2. `python3 -I -c 'import pathlib,sys; ps=["docs/workflows/step-deadline-and-retry.md","docs/builtin-gateway-json.md"]; bad=[f"{p}:{i}" for p in ps for i,l in enumerate(pathlib.Path(p).read_text().splitlines(),1) if l!=l.rstrip()]; print("\n".join(bad) or "ok"); sys.exit(bool(bad))' 2>&1 | tee tmp/issue-188/p06-ws.log` → prints `ok`.
3. `python3 -I -c 'import pathlib,sys; t=pathlib.Path("docs/workflows/step-deadline-and-retry.md").read_text(); req=["deadlineMs","maxAttempts","initialDelayMs","maxDelayMs","deterministic","outcome-unknown","retry-after-exceeds-max-delay","deadline-exhausted","riela.step.attempt.finished","riela.step.retry.stopped","collect-partial","180000","600000","120000","rielaRetry"]; miss=[r for r in req if r not in t]; print(miss or "ok"); sys.exit(bool(miss))' 2>&1 | tee tmp/issue-188/p06-terms.log` → prints `ok`.

## Edit safety

- Re-read `docs/builtin-gateway-json.md` before editing, and record pre- and post-edit sha256.
- Insert only the new subsection.

## Completion criteria

- [ ] Both files written as specified.
- [ ] Verification 1–3 exit 0, with log paths recorded.
- [ ] Only writePaths and this plan file are changed.

## Progress Log

### Session: 2026-11-10
**Tasks Completed**: Plan authored (Opus).
**Blockers**: None.
