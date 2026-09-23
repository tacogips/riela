# Gateway SDK dependency decision and unresolved release evidence

## Retained operator decision

Use public exact-version dependencies. Do not replace them with local paths,
aliases, revisions, or different versions without an explicit operator decision.
The earlier worktree-path options are historical and no longer pending choices.

| Repository under https://github.com/tacogips/ | Exact version | Locally observed v-prefixed tag commit |
| --- | --- | --- |
| gateway-sdk-kit.git | 0.1.0 | 4d4b56c686f6875defccb54f74e2276022eb524e |
| wrike-gateway.git | 0.2.4 | 1f8b27ef4cc50bfcf245b519f307d4255dbea875 |
| google-analytics-gateway.git | 0.1.1 | 0cca5a534b126637f3600605030d8f37aee6303e |
| gmail-gateway.git | 0.1.11 | b023b883fc8000ba65690c583e557131d762f91a |
| google-documents-gateway.git | 0.3.1 | 649d95efb7ade0bfc4e2f5450439b62697daeeb3 |
| apple-gateway.git | 0.1.7 | 190224f4e8af6c89e34c657f69f292bf40d6ca15 |

## D1 — high, unresolved: Google Documents release does not match the supplied contract

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

Required resolution: obtain an explicit corrected dependency/release decision
from the operator. Preserve 0.3.1 in the design meanwhile;
acceptance for implementation is blocked. This is a dependency contract issue,
not a Riela workflow provenance/readiness issue.

## Reproduction and evidence

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

After D1 is resolved and implementation is authorized, edit only the requested
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

## Step 3 review response — comm-000004

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
comm-000004. D1 is unresolved, not repaired or waived. Further author retries
without new release evidence or a dependency decision cannot clear this finding;
route this handoff for that input rather than treating another unchanged review
as acceptance. The existing selected pin remains unchanged.
