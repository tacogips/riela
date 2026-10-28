# Uniform subcommand `--help` (#184)

Issue: https://github.com/tacogips/riela/issues/184

Baseline: `main` @ `a30065e7`. No earlier design covers CLI help behavior.
`design-control-surface-parity.md` owns `CLISurfaceEnumerator`, which this
design reuses as the list of command paths. `design-automatic-retention.md`
already skips retention when `--help`/`-h` is present; that stays unchanged.

## 1. Problem (verified by reading the code at `a30065e7`)

- `riela storage compact --help` and `-h` print
  `{"error":"helpRequested(visibility: ...)"}` and exit 1.
  `StorageCompactCommandRunner.run` (`Sources/RielaCLI/StorageCompactCommand.swift:73`)
  calls `ParsedStorageCommandArguments.parse(tokens)`, and ArgumentParser
  throws `CleanExit.helpRequested`. The catch at line 96 passes it to
  `StorageCommandFailure.result` (`StorageDoctorCommand.swift:357`), which
  JSON-encodes `String(describing: error)`. `doctor storage --help` takes the
  same path.
- Help detection happens per command, and most paths check required
  arguments first:
  - `isHelpOption` (`RielaCommand.swift:649`) is used only for `workflow`,
    `workflow register`, `workflow run`, and package help.
  - `session status|progress|health|continue|step-runs|export|logs`
    (`RielaCommand+SessionParsing.swift:126`) fail with
    "session X requires a session id".
  - `workflow validate|inspect|usage|checkout|create|self-improve`
    (`RielaCommand.swift:605`) fail with "workflow X requires a workflow name".
  - Bare `serve --help` reaches `parseScoped`. The passthrough capture puts
    `--help` into the options with `command == nil`, which the bare-serve
    check (`ServeHTTPCommand.swift:13`) treats as the long-running listener.
    This is from reading the code; it was not run.
  - When a passkey origin is configured, `auth invite --help` reaches
    `PasskeyCommand.run`, which creates an invite for a user named `--help`.
    Its help check matches exact forms only (`PasskeyCommand.swift:23`).
- Some runners already print their own help whenever any `--help`/`-h` token
  is present, and exit 0: `gc` (`GarbageCollectionCommand.swift:14`),
  `session prune`, `session reconcile`, `cache`, and `environment`. `sandbox`,
  `worker`, `auth`, and `gateway` handle only exact forms such as
  `["--help"]`.

## 2. Behavior

### 2.1 Help-request rule (one central rule)

Every invocation goes through one detector, `CLIHelpRequest.detect(arguments)`,
in a new file `Sources/RielaCLI/CLISubcommandHelp.swift`.
`RielaCLIApplication.runParsed` calls it first, before the `sandbox`, `auth`,
and `worker` pre-dispatch and before `parser.parse`. If it returns a request,
`runParsed` returns the rendered help (§2.3). Otherwise dispatch continues
exactly as today.

1. **Tokens considered.** Only argv tokens before the first `--` terminator.
   Tokens after `--` belong to a child program or a workflow and never
   request help.
2. **Help token.** The exact tokens `--help` or `-h`, anywhere after the
   command path. A help token is treated as a help request even when it sits
   where an option value would go (`--message --help`). To pass a literal
   `--help` value, use `--option=--help`. This matches the existing
   `contains(--help)` checks (package, register, run, prune, reconcile, cache,
   environment) and the documented rule that leading-dash values use the
   `--option=<value>` form. No riela option uses `-h` for anything else; the
   only short flag in RielaCLI is `setup container -y`.
3. **Command path.** Use the longest prefix of argv that equals a path from
   `CLISurfaceEnumerator.commands()`, plus `sandbox` and `sandbox run`
   (sandbox is dispatched before the router and is not enumerated). If no
   path matches but `argv[0]` is a router command name or
   `sandbox`/`auth`/`worker`, the path is `[argv[0]]`. In the
   `workflow run <target>` case, the first non-dash token after the path is
   kept as the run target.
4. **Not intercepted** (the detector returns nil, and behavior is unchanged):
   - Empty path (`riela --help`, `riela -h`, `riela`): the existing top-level
     help stays as it is.
   - Unknown first token: the existing unknown-command error stays.
   - Runners that already own their help for any help token: `gc`,
     `session prune`, `session reconcile`, `cache …`, `environment …`.
   - `gateway <name> …` with `<name>` ≠ `list`: arguments are forwarded to
     the in-process gateway, whose native `--help` is the contract
     (`GatewayCommandTests`).

### 2.2 Output contract

- Exit `0` (`CLIExitCode.success`). Usage goes to stdout, stderr is empty.
- Help is always plain text. `--output json|jsonl|table` is ignored when help
  is requested, as `workflow run --help` already does.
- No command body runs. Nothing is read from or written to a store, nothing
  is invited, no listener starts.

### 2.3 Help text source (no new usage strings)

Pick the first rule that applies:

1. **Existing dedicated text.** These producers already exist. Producers
   that are inline literals today are moved into a shared constant or
   function that both the runner and the renderer use. The wording does not
   change.
   - `package …` → `packageHelpText(scope: .package)`;
     `workflow package …` → `packageHelpText(scope: .workflowPackage)`
   - `workflow run [<target>]` → `workflowRunHelpText(target:)`
   - `workflow register` → `workflowRegisterHelpText`
   - `auth …` → `PasskeyCommand.help`
   - `worker …` → the existing worker usage block
     (`DistributedWorkerCommand.swift:129`), extracted to a constant
   - `sandbox …` → the existing
     `"riela sandbox run [options] -- executable [arguments]\n" + SandboxRunArguments.helpMessage()`,
     extracted to a function
   - `gateway`, `gateway list` → `GatewayCommand.help`
2. **Usage-line slice of `rielaCLIHelpText`.** The output is `Usage:` followed
   by every line of the `Usage:` block that:
   - starts with `riela ` after trimming, and
   - has leading command words that match the path word by word, where an
     alternation word `a|b|c` matches any alternative and the line may have
     extra words after the path.

   Each matched line keeps its continuation lines, meaning the immediately
   following lines indented more deeply (the second `riela gc` line, the
   `[--sandbox …]` line of `riela node run`). If the full path matches no
   line, drop the last path word and retry. Examples:
   - `storage compact` → `riela storage compact [--apply] [--max-batch <n>] [--abandoned-after-hours <h>] [--allow-live-vacuum] [--output text|json]`
   - `session status` → `riela session status|continue|step-runs|export|logs <session-id> [options]`
   - `workflow validate` → `riela workflow validate <workflow> …`
   - `events validate` → falls back to `[events]` →
     `riela graphql|gql|hook|events|serve|call-step|workflow-call [command] [target] [options]`
3. **Full `rielaCLIHelpText`.** Used when no path prefix matches any line.
   Today this applies to `kaiba …`, `routine …` and `version`, which have no
   usage line. No new strings are written for them (§5).

### 2.4 `CleanExit` is never an error

With the detector in place, ArgumentParser never sees a help token on an
intercepted path. As a backstop, the shared error mappers also treat
`CleanExit` as a non-error:

- `StorageCommandFailure.result(_:usagePath:)`: callers pass
  `["storage","compact"]` or `["doctor","storage"]`. A `CleanExit` returns
  the §2.3 help for that path with exit 0. It is never JSON-encoded.
- `RielaClientFamilyArguments.parseCLI` (the shared ArgumentParser wrapper
  most family parsers use) rethrows `CleanExit` unchanged instead of wrapping
  it in `CLIUsageError`.
- The final `catch` in `RielaCLIApplication.runParsed` maps `CleanExit` to
  the §2.3 help for the command path resolved from the arguments, with exit 0.

Other ad-hoc wrappers of the form `catch { throw CLIUsageError(Self.message(for:)) }`
are not changed. The detector makes them unreachable for help tokens, and the
audit test (§3) checks this.

### 2.5 Unchanged

- Parse-level help returns in `RielaArgumentParser.parse`: `.help`,
  `.packageHelp`, `.workflow(.runHelp)`, `.workflow(.registerHelp)`. They
  stay correct, and `CommandParsingTests` asserts them. No new per-command
  checks are added there.
- ArgumentParser-style `USAGE:` output of the delegated runners (`gc`,
  `session prune`, `session reconcile`, `cache`, `environment`) is kept.
- `AutomaticRetentionHook` skip behavior is unchanged.

## 3. Verification

New file `Tests/RielaCLITests/SubcommandHelpTests.swift`:

- `storage compact --help` and `-h` through `RielaCLIApplication().run`: exit
  `.success`, stderr empty, stdout contains the `riela storage compact
  [--apply]` line, and stdout contains neither `helpRequested` nor
  `"error"`. Same checks for `doctor storage --help`.
- Representative required-argument commands: `session status --help`,
  `session resume -h`, `workflow validate --help`, `workflow inspect --help`,
  `workflow delete --help`, and `loop start --help`. Each prints its matching
  usage line and exits 0.
- **Audit:** for every `CLISurfaceEnumerator.commands()` path that is not in
  the delegated set, combined with each of `--help` and `-h`:
  - `CLIHelpRequest.detect` is non-nil, and
  - the rendered result has exit 0, empty stderr, non-empty stdout, and no
    `helpRequested`.

  The audit checks the detector and renderer only, so a regression cannot
  start `serve`, write to a store, or invite a user. Delegated runner paths
  (`gc`, `session prune`, `session reconcile`, `cache <op>`,
  `environment <op>`) run through `RielaCLIApplication().run` and must exit
  0. That is safe because those runners return help before doing any work.
- Edge cases:
  - `sandbox run --backend auto -- prog --help` is not intercepted.
  - `gateway <name> --help` is not intercepted.
  - `workflow run demo --help` still renders `workflowRunHelpText(target: "demo")`.
  - `auth invite --help` prints the Passkey help and creates no invite.
- `StorageCommandFailure.result(CleanExit.helpRequested(), usagePath: ["storage","compact"])`
  returns exit 0 and usage.

Commands to run:

- `arch -arm64 /bin/zsh -lc 'swift build && swift test --filter RielaCLITests'`
- `arch -arm64 /bin/zsh -lc '.build/debug/riela storage compact --help; echo $?'`
  and the same with `-h`, `session status --help`, and
  `workflow validate --help`: each prints usage, then `0`.

## 4. Rollout

- Single change set in `Sources/RielaCLI` and `Tests/RielaCLITests`.
- No backward-compatibility shims, and no data or schema impact.
- Behavior changes, all from an error or an unintended action to exit 0 plus
  usage:
  - `storage compact --help` and `doctor storage --help` no longer print
    error JSON.
  - Required-argument commands print usage instead of a missing-argument
    error.
  - `serve --help` no longer starts the listener.
  - `auth invite --help` no longer creates an invite.
  - `workflow --help` and other family-only help print the family's usage
    lines instead of the full help. The existing assertions in
    `WorkflowTemporaryRegistrationTests+Matrix` still hold: the slice
    contains `workflow register` and `--exclude-mutable`.

## 5. Decisions and open points

- **D1:** One detector in `RielaCLIApplication.runParsed`. Help for paths is
  not added inside each parser.
- **D2:** Help text comes only from existing producers or slices of
  `rielaCLIHelpText`. Families without a usage line (`kaiba`, `routine`,
  `version`) get the full top-level help. Adding usage lines for them would
  be a separate change and is out of scope for #184.
- **D3:** A help token before `--` always wins, even in a value position.
  Literal values use `--opt=--help`.
- **D4:** Runners that already return help for any help token stay delegated
  and keep their ArgumentParser `USAGE:` style.

No user decision is blocking; nothing was added under `design-docs/user-qa/`.
