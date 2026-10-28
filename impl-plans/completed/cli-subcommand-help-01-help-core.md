# ch-01-help-core: central subcommand help detector and renderer (#184)

```json
{
  "planId": "ch-01-help-core",
  "planPath": "impl-plans/active/cli-subcommand-help-01-help-core.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "Sources/RielaCLI/CLISubcommandHelp.swift",
    "Sources/RielaCLI/SandboxCommand.swift",
    "Sources/RielaCLI/DistributedWorkerCommand.swift",
    "Tests/RielaCLITests/SubcommandHelpTests.swift",
    "impl-plans/progress/ch-01-help-core.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Issue #184: `riela storage compact --help` prints
`{"error":"helpRequested(...)"}` and exits 1. Many subcommands also check
required arguments before they look for `--help`. For example,
`session status --help` fails with "requires a session id".

The accepted design is `design-docs/specs/design-cli-subcommand-help.md`
(§2.1–§2.3, §3, decisions D1–D5). It adds one central help detector and one
renderer. This plan builds only those two pure pieces and their unit/audit
tests. Plan ch-02 wires them into `RielaCLIApplication`. Plan ch-03 uses the
renderer in the storage error mapper.

Repository facts you need:

- `CLISurfaceEnumerator.commands()` (`Sources/RielaCLI/CLISurfaceEnumeration.swift`)
  returns every command path, including `["auth", action]`, `["worker"]` and
  `["worker", action]`. It does not include `sandbox`.
- `CLISurfaceEnumerator.routerCommandNames()` returns the router's first-level
  names.
- `rielaCLIHelpText` (`Sources/RielaCLI/RielaCLIApplication.swift:308`) has a
  `Usage:` block. Entry lines are indented 2 spaces and start with `riela `.
  Continuation lines are indented more deeply: the second `riela gc` line and
  the `[--sandbox …]` line under `riela node run`. The block ends at the
  first empty line.
- Existing dedicated help producers:
  - `packageHelpText(scope:)` and `workflowRunHelpText(target:)` in
    `RielaCLIApplication.swift`
  - `workflowRegisterHelpText` (`WorkflowMutableRegistrationCommand.swift:126`)
  - `PasskeyCommand.help` (`PasskeyCommand.swift:5`)
  - `GatewayCommand.help` (`GatewayCommand.swift:131`)
  - the sandbox help inline literal (`SandboxCommand.swift:28`)
  - the worker help inline literal (`DistributedWorkerCommand.swift:128-137`)
- `PackageHelpScope` (`RielaCommand.swift:110`): `.package`,
  `.workflowPackage`.

## Non-goals

- Do not edit `RielaCLIApplication.swift`, `RielaClientFamilyArguments.swift`,
  `RielaCommand.swift`, `StorageCompactCommand.swift` or
  `StorageDoctorCommand.swift`. They belong to ch-02, ch-03, or stay unchanged.
- Do not add new usage strings, and do not change the wording of any
  existing help text.
- Do not change parse-level help in `RielaArgumentParser`
  (`.help`, `.packageHelp`, `.workflow(.runHelp)`, `.workflow(.registerHelp)`).
- No generic help framework, no configuration, no changes to
  `CLISurfaceEnumerator`.

## Pinned contract (ch-02 and ch-03 depend on these exact names)

All types are internal, in the new file `Sources/RielaCLI/CLISubcommandHelp.swift`:

```swift
struct CLIHelpRequest: Equatable, Sendable {
  var path: [String]
  var runTarget: String?
  static func detect(_ arguments: [String]) -> CLIHelpRequest?
  static func resolve(_ arguments: [String]) -> CLIHelpRequest?
}
enum CLISubcommandHelp {
  static func result(for request: CLIHelpRequest) -> CLICommandResult
  static func result(path: [String]) -> CLICommandResult
  static func isCleanExit(_ error: any Error) -> Bool
}
```

The new file has `import ArgumentParser` so that `isCleanExit` can test
`error is CleanExit`. Callers in ch-02 and ch-03 must not need to import
ArgumentParser.

## Semantics

### `resolve(arguments)`: command path only, no help-token requirement

1. Consider only the tokens before the first exact `--`.
2. Known paths are `CLISurfaceEnumerator.commands().map(\.path)` plus
   `["sandbox"]` and `["sandbox", "run"]`. Pick the longest known path that
   is a prefix of the considered tokens.
3. If no known path matches but `tokens[0]` is in
   `CLISurfaceEnumerator.routerCommandNames()` or is `sandbox`, `auth` or
   `worker`, the path is `[tokens[0]]`.
4. Return nil when there are no tokens or the first token is unknown
   (including when it starts with `-`).
5. `runTarget`: only when the path is `["workflow", "run"]`, set it to
   `tokens[2]` if that token exists and does not start with `-`.

### `detect(arguments)`: help request

1. Return nil unless one of the tokens before the first `--` is exactly
   `--help` or `-h`.
   - Check this first, so that normal invocations never enumerate the CLI
     surface.
   - `-help`, `help` and `--help=x` are not help tokens.
2. Then call `resolve`. Return nil if it returns nil.
3. Return nil for the delegated paths. Their runners already print help:
   - path `== ["gc"]`
   - path `== ["session", "prune"]`
   - path `== ["session", "reconcile"]`
   - `path.first == "cache"`
   - `path.first == "environment"`
   - path `["gateway", name]` with `name != "list"` (native gateway help)
4. Otherwise return the resolved request.

### `result(for:)` and `result(path:)`

Both always return `CLICommandResult(exitCode: .success, stdout: text)` with
empty stderr. They are total: any path, including a delegated one, renders
something. `result(path:)` is the same as `result(for:)` with
`runTarget: nil`. The first matching rule picks the text:

1. **Dedicated text.**
   - `path.first == "package"` → `packageHelpText(scope: .package)`
   - path starts with `["workflow", "package"]` →
     `packageHelpText(scope: .workflowPackage)`
   - `["workflow", "run"]` → `workflowRunHelpText(target: runTarget)`
   - `["workflow", "register"]` → `workflowRegisterHelpText`
   - `path.first == "auth"` → `PasskeyCommand.help + "\n"`, exactly what
     `PasskeyCommand.run` prints today
   - `path.first == "worker"` → `DistributedWorkerCommand.helpText` (new
     constant, below)
   - `path.first == "sandbox"` → `SandboxCommand.helpText` (new static
     computed property, below)
   - `["gateway"]` or `["gateway", "list"]` → `GatewayCommand.help`
2. **Usage-line slice of `rielaCLIHelpText`.**
   - Take the lines after the `Usage:` line, up to (not including) the first
     empty line.
   - An entry line is one whose trimmed text starts with `riela `.
   - Split an entry line's trimmed text on single spaces. Word `i+1`, split
     on `|`, must contain `path[i]` for every `i`. The line may have extra
     words after the path.
   - Each matched entry line is followed by its continuation lines: the
     immediately following lines whose leading-space count is greater than
     the entry line's, and whose trimmed text does not start with `riela `.
     The two-space note `Leading-dash values …` is never included.
   - Output: `"Usage:\n"`, then the matched lines with their original
     indentation joined by `"\n"`, then a trailing `"\n"`.
   - If no line matches, drop the last path word and retry.
3. **Full `rielaCLIHelpText`** when the path becomes empty without a match.
   This happens today for `kaiba …`, `routine …` and `version`.

### Constant extraction (no wording change)

- `SandboxCommand.swift`: add `static var helpText: String` that returns
  exactly
  `"riela sandbox run [options] -- executable [arguments]\n" + SandboxRunArguments.helpMessage()`.
  Make line 28 use it. Keep the existing `arguments == ["--help"] || arguments == ["run", "--help"]`
  condition unchanged.
- `DistributedWorkerCommand.swift`: move the multi-line literal returned for
  `["worker", "--help"]` into `static let helpText = """ … """`, byte for
  byte identical. Make the existing branch return it. Change nothing else.

## Pitfalls

- Do not match usage lines by substring. `session status` must not match
  `riela session list`, and `workflow version` must not match
  `riela workflow versions`. Compare whole words; only `|` splits
  alternatives.
- `workflow version` (2 words) must match both `riela workflow version show`
  and `riela workflow version diff`, because the path is a prefix of each.
- Tokens after `--` never count: `sandbox run --backend auto -- prog --help`
  → nil.
- `detect` must not mutate anything or touch the file system.
- Do not use `CLISurfaceEnumerator.optionNames()`.
- Avoid any static cache that needs `nonisolated(unsafe)`. Recomputing on a
  help request is fine.
- Keep `swiftlint --strict` clean. Watch `cyclomatic_complexity` (warning
  30): split rule 1 into a small helper if needed.

## Tests (`Tests/RielaCLITests/SubcommandHelpTests.swift`, `@testable import RielaCLI`)

Detector cases (input → expected):

- `["storage","compact","--help"]` and `["storage","compact","-h"]` →
  path `["storage","compact"]`
- `["session","status","--help"]` → `["session","status"]`
- `["workflow","validate","--help"]` → `["workflow","validate"]`
- `["workflow","run","demo","--help"]` → path `["workflow","run"]`,
  runTarget `"demo"`
- `["workflow","run","--help"]` → runTarget nil
- `["session","--help"]` → `["session"]`
- `["workflow","--help"]` → `["workflow"]`
- `["serve","--help"]` → `["serve"]`
- `["auth","invite","--help"]` → path starts with `"auth"`
- `["workflow","run","demo","--message","--help"]` → non-nil (D3)
- Returns nil:
  - `["--help"]`, `["-h"]`, `[]`, `["bogus","--help"]`
  - `["sandbox","run","--backend","auto","--","prog","--help"]`
  - `["gateway","gmail","--help"]`
  - `["gc","--help"]`, `["session","prune","--help"]`,
    `["session","reconcile","-h"]`
  - `["cache","put","--help"]`, `["environment","status","-h"]`
  - `["workflow","validate","demo"]` (no help token)
  - `["workflow","run","demo","--message=--help"]`
- `["gateway","list","--help"]` → non-nil

Renderer cases:

- `result(path: ["storage","compact"])`:
  - exit `.success`, empty stderr
  - stdout starts with `"Usage:\n"` and contains
    `riela storage compact [--apply] [--max-batch <n>] [--abandoned-after-hours <h>] [--allow-live-vacuum] [--output text|json]`
  - stdout does not contain `riela doctor storage`
- `["session","status"]` → contains
  `riela session status|continue|step-runs|export|logs <session-id> [options]`,
  does not contain `riela session list`
- `["workflow","validate"]` → contains `riela workflow validate <workflow>`
- `["workflow","version"]` → contains `riela workflow version show` and
  `riela workflow version diff`, does not contain `riela workflow versions`
- `["gc"]` → contains both `riela gc [--scope` and the continuation
  `[--messages-max-age-days N]`
- `["node","run"]` → contains `[--sandbox auto|container|seatbelt|bubblewrap]`
- `["events","validate"]` →
  `riela graphql|gql|hook|events|serve|call-step|workflow-call`
- `["kaiba","instance","list"]` → stdout equals `rielaCLIHelpText`
- `["workflow"]` → contains `workflow register` and `--exclude-mutable`
- `result(for: CLIHelpRequest(path: ["workflow","run"], runTarget: "demo"))`
  → stdout equals `workflowRunHelpText(target: "demo")`
- `["package","install"]` → equals `packageHelpText(scope: .package)`
- `["workflow","package","install"]` →
  `packageHelpText(scope: .workflowPackage)`
- `["auth","invite"]` → contains `Passkey`
- `["sandbox","run"]` → equals `SandboxCommand.helpText`
- `["worker"]` → equals `DistributedWorkerCommand.helpText`

Audit (design §3 plus the Step 3 low finding):

- For every `CLISurfaceEnumerator.commands()` path and each of `--help` and
  `-h`, skip it when the path is delegated or matches `["gateway", x]` with
  `x != "list"`.
- For each remaining path, `detect(path + [token])` must be non-nil, and
  `CLISubcommandHelp.result(for:)` must give:
  - exit `.success`
  - empty stderr
  - non-empty stdout
  - stdout not containing `helpRequested`
  - stdout not starting with `{"error"`
- Also assert that the audited count is at least 50, so the audit cannot
  pass vacuously.

`isCleanExit` cases:

- `XCTAssertFalse(CLISubcommandHelp.isCleanExit(CLIUsageError("x")))`
- Getting a real `CleanExit` without importing ArgumentParser: call
  `ParsedStorageCommandArguments.parse(["--help"])` inside `do/catch`. The
  type is internal and visible via `@testable`.
  - If calling `parse` does not compile without importing ArgumentParser,
    skip this assertion.
  - Record the skip in the progress log.
  - ch-03 covers the real CleanExit path end to end.

## Verification (logs under `tmp/issue-184/ch-01/`)

1. `mkdir -p tmp/issue-184/ch-01`
2. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/issue-184/ch-01/build.log 2>&1'`
   → exit 0.
3. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter SubcommandHelpTests > tmp/issue-184/ch-01/test.log 2>&1'`
   → exit 0 and "0 failures".
4. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter "WorkflowRunHelpTests|PasskeyCommandTests|GatewayCommandTests|SandboxContainerShareValidationTests" > tmp/issue-184/ch-01/test-neighbors.log 2>&1'`
   → exit 0.
5. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/CLISubcommandHelp.swift Sources/RielaCLI/SandboxCommand.swift Sources/RielaCLI/DistributedWorkerCommand.swift Tests/RielaCLITests/SubcommandHelpTests.swift > tmp/issue-184/ch-01/swiftlint.log 2>&1'`
   → exit 0 and an empty log.
6. `git diff --quiet -- Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/RielaClientFamilyArguments.swift Sources/RielaCLI/RielaCommand.swift Sources/RielaCLI/StorageDoctorCommand.swift Sources/RielaCLI/StorageCompactCommand.swift`
   → exit 0. Run this before any wave-2 work has started; if ch-02 or ch-03
   is already running, record the drift instead.

## Concurrency hygiene

- Re-read each owned file right before editing it.
- Record SHA-256 hashes (`shasum -a 256`) of the owned files before and
  after the work in the progress log.
- Edit only your `writePaths`. If an owned file changed unexpectedly between
  your read and your write, stop and record the drift.
- No git write operations.

## Done criteria

- `CLISubcommandHelp.swift` exists with exactly the pinned names.
  `grep -c "nonisolated(unsafe)\|@unchecked" Sources/RielaCLI/CLISubcommandHelp.swift`
  prints `0`.
- `SandboxCommand.helpText` and `DistributedWorkerCommand.helpText` exist,
  and the existing branches use them.
  `git diff Sources/RielaCLI/SandboxCommand.swift Sources/RielaCLI/DistributedWorkerCommand.swift`
  shows no change to the help wording.
- All verification commands meet their expected results.
- `impl-plans/progress/ch-01-help-core.md` records:
  - changed symbols
  - pre/post SHA-256 of the owned files
  - the audited path count
  - any skipped assertion
  - a verification table: command, exit status, tests run, failures, log
    path
