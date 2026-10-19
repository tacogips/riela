# Reject local process invocations before expired/cancelled dispatch

Issue: https://github.com/tacogips/riela/issues/157

## Scope

`FoundationLocalProcessRunner` already owns its process group and waits for cleanup
on timeout/cancellation. Its admission path currently calls `posix_spawn` before
checking an expired deadline or cancellation that predates the invocation. This
can start a command after its caller's authority to execute has ended.

ART's separate credential wrapper timeout is caller-owned and is not attributed
to this runtime defect. Existing command-node deadline forwarding, memory/cache
checkpoints and CLI signal cancellation remain the integration contract.

## Implementation

- Reproduce with a missing executable: expired/cancelled invocations must return
  their timeout/cancellation result before executable resolution, not ENOENT.
- Check task cancellation and an already-expired deadline before sandbox planning
  and immediately before spawn; preserve the existing in-flight cleanup path.
- Validate ordinary command execution, foreground/background lifetime, process
  group ownership, output framing and stdin cancellation tests.
- Include the reviewed fix in the next coordinated patch release with the separate
  startup hydration performance fix; no unrelated dependency updates.

## Limits

A cancellation racing with the actual OS spawn still uses the existing owned
process-group cleanup. SIGKILL and descendants deliberately escaping a process
group are not newly claimed to be recoverable. This change adds no retries and
never replays an uncertain command.

## Validation

- Baseline: both admission regressions fail on0.2.20 with providerError/ENOENT.
- Fixed:25 local-process lifetime/ownership/framing/stdin and command-stdio tests
  pass, including both admission regressions.
- SwiftLint on both changed Swift files passes; diff whitespace check passes.
- Independent source review found no blocker; original in-flight cancellation
  latch and descriptor ownership remain intact.
