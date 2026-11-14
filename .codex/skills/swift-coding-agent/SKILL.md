---
name: swift-coding-agent
description: "Use when Codex is asked to implement, refactor, review, or maintain Swift code in SwiftPM, Xcode, iOS, macOS, watchOS, tvOS, or server-side Swift projects. This skill enforces SwiftLint execution, splits Swift files over 1000 lines into meaningful responsibility-based files, and guides maintainable Swift design using DRY, single responsibility, SOLID, established design patterns, tests, and project-local conventions."
---

# Swift Coding Agent

## Core Workflow

1. Inspect the project before editing:
   - Locate `Package.swift`, `*.xcodeproj`, `*.xcworkspace`, `.swiftlint.yml`, `.swiftformat`, `Makefile`, CI workflows, and existing test targets.
   - Read nearby source and tests to match naming, access control, dependency injection, error handling, concurrency style, and formatting.
   - Use `rg --files -g '*.swift'` and `wc -l` to identify Swift files over 1000 lines.

2. Plan changes around existing boundaries:
   - Prefer the repository's current architecture and module boundaries over new abstractions.
   - Keep behavior changes narrow unless the user asks for broader redesign.
   - Preserve public API compatibility unless an intentional breaking change is requested.

3. Implement with maintainability as a hard requirement:
   - Apply DRY, single responsibility, SOLID, clear ownership, cohesive types, and testable seams.
   - Use common Swift patterns when they reduce complexity: protocol abstraction for boundaries, value types for immutable data, strategy/state/delegate/coordinator where already idiomatic, and small extensions for focused protocol conformances.
   - Avoid over-engineering: add abstractions only when they remove real duplication, isolate unstable dependencies, or match an existing local pattern.

4. Verify:
   - Run SwiftLint after edits.
   - Run the narrowest relevant test/build command, then broaden if shared behavior changed.
   - Fix lint, compile, and test failures caused by the work before handing off.

## SwiftLint

Always try to run SwiftLint for Swift code changes:

```bash
swiftlint
```

When the repository uses a Nix flake and Xcode's Swift toolchain, prefer the
project shell with Xcode toolchain variables so SwiftLint can load SourceKit:

```bash
nix develop -c bash -lc 'export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk; export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault; export PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH; swiftlint'
```

If the project uses a wrapper, prefer it:

```bash
make lint
swift package plugin --allow-writing-to-package-directory swiftlint
bundle exec swiftlint
mint run realm/SwiftLint swiftlint
```

If SwiftLint is unavailable, report that clearly and still run available Swift formatting/build/tests. Do not silently skip lint.

Handle lint findings by fixing code. Use `// swiftlint:disable` only when a rule is demonstrably wrong for a localized case, scope it to the smallest block or line, and include a short reason if the repository style allows comments.

## Splitting 1000+ Line Files

Treat any non-generated Swift file over 1000 lines as a refactoring target. Do not split by mechanical numbered suffixes such as `File1.swift`, `File2.swift`, or `File+Part2.swift`.

Split by meaningful units:

- One primary type per file when practical: `OrderViewModel.swift`, `CheckoutCoordinator.swift`, `UserSessionStore.swift`.
- Group related small types by responsibility: `PaymentModels.swift`, `WorkflowValidationErrors.swift`, `SettingsViewActions.swift`.
- Move protocol conformances into named extension files when they are substantial: `UserProfileViewModel+Navigation.swift`, `WorkflowRunner+Persistence.swift`.
- Separate UI composition, state, domain logic, persistence, networking, parsing, and test fixtures when they have distinct reasons to change.
- Keep private helpers near the only type that uses them unless sharing is intentional.

Before splitting:

- Identify type declarations, extensions, nested types, file-private helpers, tests, and comments that describe file-level context.
- Check access control. Moving code can require changing `private` to `fileprivate` or restructuring helpers; prefer keeping encapsulation strong over widening access.
- Preserve generated-code markers. Do not refactor generated files unless the user explicitly asks.

After splitting:

- Ensure moved symbols remain in the same target/module.
- Re-run search for old filenames and references.
- Build/test to catch target membership or access-control regressions.

## Swift Design Standards

Use Swift idioms:

- Prefer `let` and immutable value types unless mutation is necessary.
- Model invalid states out of existence with enums, optionals, throwing initializers, and typed errors.
- Actively look for stringly typed domains during implementation and review. Prefer `RawRepresentable` enums for fixed modes, statuses, sort orders, roles, strategies, and policy values when invalid values should fail closed.
- Do not add `String` fields for producer-owned closed DTO values. Public command/API result fields such as `sourceKind`, provenance kind, status, mode, role, policy, or decision should be typed as enums, usually `enum Name: String, Codable, Equatable, Sendable`, with stable raw values for JSON and CLI compatibility.
- Keep `.rawValue` at wire/rendering boundaries. Internal branching, tests, and DTO construction should use enum cases such as `.workflow` or `.package`, not ad-hoc string literals.
- For external protocol fields with arbitrary future values, prefer lossless open enums with known cases plus `custom(String)` when the type clarifies behavior without rejecting unknown data. Codable must decode unknown strings into `.custom`, encode back the exact original string, and preserve JSON/CLI/GraphQL/persisted raw spellings.
- Keep validation and dispatch strict even for open enums: known supported cases may dispatch; `.custom` values should usually round-trip, log, or surface diagnostics, but must not be accidentally treated as supported.
- Keep each external protocol field to one canonical wire format. Do not decode both numeric and string dates, multiple casing variants, or alternate spellings unless an explicit compatibility requirement exists; encode only the canonical form and reject non-canonical input at the boundary.
- Distinguish value vocabulary from wire format. A field may preserve unknown future vocabulary through `custom(String)`, but fields that drive routing, validation, authorization, dispatch, or app behavior should still expose supported/unsupported cases explicitly and fail closed for unsupported values.
- Do not force enums onto values that gain no behavioral clarity, such as free-form ids, file paths, prompt templates, user-authored payload keys, or arbitrary message text.
- When a string domain is repeated across modules, normalize once through a shared enum/helper only if the behavior truly matches. Keep domain-specific discovery, fallback, error handling, and compatibility differences separate.
- Keep async code structured with `async`/`await`, `Task`, and actor isolation consistent with existing code.
- Keep UI logic thin. Put domain rules in models/services/view models that can be tested without UI frameworks.
- Avoid force unwraps, implicitly unwrapped optionals, global mutable state, hidden singletons, and broad catch-all error swallowing.
- Prefer dependency injection for clocks, file systems, network clients, persistence, and external processes when tests need determinism.
- Extract repeated or semantically important literals into named constants or typed domains near their owner before adding more call sites. Prefer meaningful owners such as `WorkflowPackage.manifestFileName`, `NodeRuntime.pathEnvironmentName`, or `MockScenario.providerName` over catch-all containers like `Constants`. Prioritize environment variable names, executable names, CLI flags, file names, JSON keys, provider/status strings, shell probe patterns, and magic numbers used in assertions. Keep one-off user-facing prose inline when naming it would add indirection without reuse or policy value.
- When filtering paths or commands by repeated prefixes, define a semantically named collection such as `ignoredRepositoryPathPrefixes` or `supportedCommandPrefixes` and use `contains(where:)`/`first(where:)`. Avoid long chains of `&& !value.hasPrefix(...)`, `|| value.hasPrefix(...)`, or sprawling `case` blocks when a data-driven table communicates the policy better and makes future additions local.
- Keep names explicit at API boundaries and concise inside local scopes.

For maintainability reviews, include a quick pass for enum candidates:

```bash
rg -n 'case "[^"]+"|== "[^"]+"|!= "[^"]+"|status: String|type: String|kind: String|mode: String|decision: String|backend: String|provider: String' Sources Tests --glob '*.swift'
```

Treat this search as a starting point. Most hits are expected boundary strings; refactor only the closed domains where typing reduces real invalid states or duplicated validation.

## Validation Commands

Choose commands from project evidence:

```bash
swift test
swift build
xcodebuild test -scheme <Scheme> -destination '<Destination>'
xcodebuild build -scheme <Scheme> -destination '<Destination>'
```

When unsure, inspect `Package.swift`, shared schemes, README, CI, and existing scripts before choosing. In final responses, report the exact lint/build/test commands run and any commands that could not run.
