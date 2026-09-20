# Implementation plan: git-commit rename guard

planId: git-commit-rename-guard-plan-1
planPath: design-docs/specs/impl-plan-git-commit-rename-guard.md
dependsOn: [] (single plan, single work package, has_feature_fanout=false)
design: design-docs/specs/design-git-commit-rename-guard.md

writePaths:
- Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift (validateCommitPaths only)
- Tests/RielaCLITests/GitWorkflowAddonContractTests.swift (new tests)
- Tests/RielaCLITests/GitWorkflowAddonTests.swift (GitTestRepository init parameter only)

sharedPaths: none (no lockfiles, no generated indexes; no other plan exists)

## Applicable prior knowledge

Knowledge-base recall for "git-commit addon rename guard" returned 0 results.
Session-verified facts to apply anyway:
- Run every Swift command through an arm64 login shell:
  `arch -arm64 /bin/zsh -lc '...'` (Rosetta shells cannot dlopen the xctest bundle).
- Never tail full-suite test output; keep complete logs and diff the failure
  set against the 10 accepted environmental failures.

## Ordered tasks

T1. Guard fix — Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift,
    `.missing` branch of validateCommitPaths (lines 301-312 at HEAD ca1ce34):
    after `ls-files --error-unmatch` exits nonzero, probe
    `runRepositoryGitResult(["cat-file", "-e", "HEAD:\(path)"], repository:)`;
    accept on exit 0, otherwise throw the UNCHANGED policy error
    "riela/git-commit missing path is not an exact tracked deletion".
    Do not touch any other validation, message, or the finalization journal.

T2. Fixture extension — Tests/RielaCLITests/GitWorkflowAddonTests.swift:
    add `commitInitialFile: Bool = true` to GitTestRepository.init. When false:
    still `git init -b main`, config user, write tracked.txt and
    `git add -- tracked.txt`, but skip the initial commit (index file must
    exist or loadGitRepository's regularPathEntryIdentity preflight fails;
    HEAD stays unborn). All existing call sites compile unchanged
    (default parameter). Keep `withBareRemote` behaviour guarded so it is not
    combined with an unborn HEAD (no push of a nonexistent branch); the new
    tests never pass both.

T3. Tests — Tests/RielaCLITests/GitWorkflowAddonContractTests.swift, following
    existing helper patterns (makeGitCommitInput, gitPayload,
    XCTAssertGitCommitEvidence, XCTAssertThrowsErrorAsync):
    a. testCommitSupportsStagedRenameAcrossOldAndNewPaths — commit fixture,
       `repository.git(["mv", "tracked.txt", "renamed.txt"])`, execute with
       files ["tracked.txt", "renamed.txt"], assert committed status +
       evidence, `rev-parse HEAD^` == pre-rename HEAD,
       `ls-tree --name-only HEAD` == "renamed.txt",
       `show HEAD:renamed.txt` == "initial". (Do not assert on
       `show --name-status`; git may render R100 rename detection.)
    b. testCommitRejectsMissingPathAbsentFromIndexAndHead — files
       ["ghost.txt"], assert .policyBlocked, HEAD unchanged, indexData()
       unchanged, finalizationArtifacts("journals") == [].
    c. testCommitRejectsMissingPathOnUnbornHeadWithoutCrashing —
       GitTestRepository(commitInitialFile: false), files ["ghost.txt"],
       assert .policyBlocked, `rev-list --all --count` == "0", no journals.

T4. Lint + targeted tests (iterate):
    `arch -arm64 /bin/zsh -lc 'swift test --filter GitWorkflowAddonContractTests'`
    and `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift Tests/RielaCLITests/GitWorkflowAddonContractTests.swift Tests/RielaCLITests/GitWorkflowAddonTests.swift'`
    (drop --strict only if the repo's lint baseline is not strict-clean for
    untouched rules; changed sources must be warning-free).

T5. Full verification from the worktree root, complete log kept:
    `arch -arm64 /bin/zsh -lc 'swift build && swift test' > /tmp/git-commit-rename-guard-full-test.log 2>&1`
    then diff the failure set against exactly the 10 accepted environmental
    failures (6 AppKit view-hierarchy: RielaAppUXOnboardingControllerTests,
    RielaAppSettingsEditorNavigationTests, RielaAppWindowContentInsetTests;
    3 unix-socket-unlink: WorkflowRound7AdversarialTests;
    WorkflowCommandTests.testPackageAppEnvironmentEnablementRunAndMonitoringScenario).
    List any difference explicitly; any other failure is in scope to fix.

T6. Commit everything (source, tests, this plan, the design doc) on
    fix/git-commit-rename-guard and push ONLY that branch. Never touch main,
    no force push. End the commit message with
    "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>".

## Dependencies

T1 independent. T3a/T3b depend on T1. T3c depends on T1+T2. T4 after T1-T3.
T5 after T4. T6 last. Parallelizable: T1 and T2 (disjoint files); everything
else serial. Single implementer, no worktrees, no parallel git.

## Acceptance criteria (traceable)

- AC1 rename end-to-end committed → T3a.
- AC2 nowhere-tracked path still refused with the same policy error → T1+T3b.
- AC3 plain tracked deletion + unborn HEAD non-regression →
  existing testCommitSupportsExactTrackedDeletion stays green + T3c.
- AC4 contract filter green; full suite == 10-failure baseline → T4+T5.
- AC5 SwiftLint clean on changed sources → T4.
- AC6 committed and pushed on fix/git-commit-rename-guard only → T6.

## Verification commands

- arch -arm64 /bin/zsh -lc 'swift test --filter GitWorkflowAddonContractTests'
- arch -arm64 /bin/zsh -lc 'swiftlint lint --strict <the three changed files>'
- arch -arm64 /bin/zsh -lc 'swift build && swift test' (full log to
  /tmp/git-commit-rename-guard-full-test.log; compare against baseline list)
- git log --stat fix/git-commit-rename-guard; git status (clean); confirm no
  push to main.

## Completion criteria

All six acceptance criteria hold with evidence (test names + full-log failure
diff), worktree clean, branch pushed.
