# Gateway SDK dependency decision and historical release evidence

## Current operator decision

Use public exact-version dependencies. Do not replace them with local paths,
aliases, revisions, or different versions without an explicit operator decision.
The earlier worktree-path options are historical and no longer pending choices.

| Repository under https://github.com/tacogips/ | Exact version | Locally observed v-prefixed tag commit |
| --- | --- | --- |
| gateway-sdk-kit.git | 0.1.0 | 4d4b56c686f6875defccb54f74e2276022eb524e |
| wrike-gateway.git | 0.2.4 | 1f8b27ef4cc50bfcf245b519f307d4255dbea875 |
| google-analytics-gateway.git | 0.1.1 | 0cca5a534b126637f3600605030d8f37aee6303e |
| gmail-gateway.git | 0.1.11 | b023b883fc8000ba65690c583e557131d762f91a |
| google-documents-gateway.git | 0.3.3 | 4baeb285f459adb9031273490b922abc8204dedb |
| apple-gateway.git | 0.1.7 | 190224f4e8af6c89e34c657f69f292bf40d6ca15 |

## Historical D1 — high at v0.3.1; resolved by the v0.3.3 decision

The locally available `google-documents-gateway` tag `v0.3.1` has no
GatewaySDKKit dependency in `Package.swift` and no `GoogleDocumentsGatewaySDK`
in its source tree. The SDK exists in the separate development worktree, which
is not evidence that this exact release contains it. No external checkout was
modified. The four other gateway tag manifests declare the public exact kit
`0.1.0` dependency; their tag-addressed source contains SDK facades.

Intake reports six public tags and says the documents release already contains
the SDK. Tag existence alone does not establish that contract. The workflow
sandbox could not resolve `github.com`, so its six `git ls-remote --exit-code`
checks exited 128. An operator-side check outside that sandbox subsequently ran
`git ls-remote --tags https://github.com/tacogips/google-documents-gateway.git
'refs/tags/v0.3.1' 'refs/tags/v0.3.1^{}'` successfully: the tag object is
`18f340d4b7ed3832412642bd8d01e92209ae85df` and the peeled commit is
`649d95efb7ade0bfc4e2f5450439b62697daeeb3e`, identical to the inspected
local tag. The selected public release therefore has the documented SDK gap;
the sandbox DNS failure is not the cause of D1.

The prior required resolution was an explicit corrected dependency/release
decision. That decision is now supplied by effective workflow input: select
0.3.3. The historical 0.3.1 gap is not repaired retroactively; it is superseded
by the verified replacement release below.

## Historical reproduction and evidence

For each repository/version in the table:

```bash
git -C /Users/taco/gits/tacogips/<repository> rev-parse 'v<version>^{commit}'
git -C /Users/taco/gits/tacogips/<repository> show v<version>:Package.swift
git ls-remote --exit-code https://github.com/tacogips/<repository>.git refs/tags/v<version> 'refs/tags/v<version>^{}'
```

All twelve local tag/manifest commands exited 0. Exact expanded argv, exit codes,
and complete log paths are in `tmp/gateway-sdk-design/commands.json`; per-command
logs are in that same gitignored folder. They are retained for workflow handoff,
not committed. The Google Documents tree check below exited 0 and found no SDK:

```bash
git -C /Users/taco/gits/tacogips/google-documents-gateway ls-tree -r --name-only v0.3.1
```

## Future dependency graph acceptance gate

After design and plan acceptance, in a later implementation-authorized run, edit only the requested
manifest dependencies and regenerate the lockfile without unrelated upgrades.
Run in this supplied Riela worktree, recording full stdout/stderr and final status:

```bash
swift package resolve
swift package show-dependencies --format json
```

Both must exit zero with no conflicting-identity warning. Check five distinct
remote gateway identities at the selected exact versions and one unique kit
identity/version 0.1.0 across the graph (shared references may repeat the same
identity in tree JSON). Inspect Package.resolved URLs, versions and revisions;
reject local path/mirror substitution and unrelated dependency changes. Neither
command was run in Step 2: the feature manifest is intentionally unmodified,
and such a graph would not validate the proposed dependency set.

No other operator decision is pending. Independent Step 3 design review and
later implementation-plan review remain required before document publication.

## Historical Step 3 review response — comm-000004

Review decision: rejected (`accepted: false`, `needs_revision: true`), solely
for high finding D1. Step 2 retried the public tag, manifest, and facade checks
in the foreground. `git ls-remote --exit-code` again exited 128; both bounded
`curl --fail --location --connect-timeout 10 --max-time 30` requests exited 6
(DNS resolution failures). Independent web-tool requests for the manifest and
facade also returned cache-miss fetch failures. None proves remote absence.

Exact expanded commands, final exit codes, and complete logs are recorded in
`tmp/gateway-sdk-design/review-retry/commands.json`; logs are `remote.log`,
`public-manifest.log`, and `public-facade.log` in the same directory.

Operator clarification was requested for verified public release evidence or an
explicit corrected exact-release decision. No such response was supplied with
comm-000004, so that historical revision correctly left D1 unresolved. The
current intake now supplies the missing decision and source evidence; the
prior rejection remains historical, not a current acceptance decision.

## Corrected release evidence and review handoff (2026-09-23)

Effective workflow input and Step 1 intake `comm-000002` approve public
`https://github.com/tacogips/google-documents-gateway.git` exact `0.3.3`, supplied
release commit `4baeb285f459adb9031273490b922abc8204dedb`. This overrides only
the Google Documents version in the historical brief; the other five public
exact-version dependencies above remain unchanged. All table repository names
expand to public HTTPS URLs under the stated prefix; none is a local dependency.

Read-only local tag verification confirms the supplied commit and all six table
commits. Each gateway release manifest declares
`.package(url: "https://github.com/tacogips/gateway-sdk-kit.git", exact: "0.1.0")`.
Google Documents v0.3.3
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsGatewaySDK.swift` declares
`GoogleDocumentsGatewaySDK: GatewaySDK`, role-scoped catalog/tier,
`init(role:...)`, throwing `buildArgv(operation:variables:)`, async
`execute(document:variables:environment:)`, and async
`invoke(_:environment:)`. `execute` consumes a JSON array of argv strings and
ignores variables. `buildArgv` validates and normalizes arguments; it does not
apply the separate execution/file policies of `execute` or `invoke`. The design
explicitly preserves the existing Riela command runner boundary.

Current verification: 13 commands, all exit 0. Exact expanded argv and individual
complete stdout/stderr log paths are in
`tmp/gateway-sdk-design-step2/commands.json`; logs are
`<repository>-tag.log`, `<repository>-manifest.log`, and
`google-documents-gateway-facade.log` in that directory. These are read-only
`git -C /Users/taco/gits/tacogips/<repository> rev-parse 'v<version>^{commit}'`
and `git ... show v<version>:Package.swift` checks, plus
`git -C /Users/taco/gits/tacogips/google-documents-gateway show v0.3.3:Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsGatewaySDK.swift`.
Public release identity is supplied by runtime input; no fresh network verification
is claimed. Logs remain gitignored for downstream review handoff.

D1 is addressed, with no unresolved operator decision. Independent design review
is pending; its acceptance must precede implementation-plan authoring. Independent
plan review is also required. Only accepted planning artifacts may later be
committed and pushed on `feat/gateway-sdk-addons`; no merge to main or Swift
implementation is authorized in this run. Future dependency graph/build/runtime
gates above belong to the later implementation run and are not claimed as passed.
