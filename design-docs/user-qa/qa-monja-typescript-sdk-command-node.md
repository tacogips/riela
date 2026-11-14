# Monja TypeScript SDK Command Node User Questions

Workflow mode: `design-plan-only`

Issue reference:
`local-request:/Users/taco/gits/tacogips/riela:Use the Monja TypeScript SDK from Riela command nodes`

These questions do not block the deterministic packed-package proof. They do
block any claim that a live Monja deployment was verified.

## Live Server Lifecycle And Data

Which Monja deployment should the optional live check use, and what
deployment-owned startup, migration, and seed procedure is authoritative?

Recommended default: do not automate live server lifecycle in this example.
Require the operator to provide an already-running HTTPS `MONJA_BASE_URL`, with
plaintext HTTP accepted only for exact loopback hosts, verify capabilities and
authentication without mutation, and document the environment used in external
evidence only.

## Credential Provisioning

Which operator procedure issues an API key with access to `/api/v1/auth/me` and
the selected GraphQL fields?

Recommended default: keep issuance and secret storage outside Riela. Export the
value as `MONJA_API_KEY` only for the process running the workflow; never place
it in workflow variables, command arguments, `.env` examples, captured output,
or committed files.

## Live GraphQL Operation

Should live verification remain the read-only
`query RielaSdkProbe { me { kind user { id username displayName } } }`, or must
it demonstrate a deployment-specific mutation?

Recommended default: retain the read-only query as the live smoke test. The
deterministic mock proves that the input accepts an arbitrary query or mutation;
an actual mutation needs a separate target, cleanup contract, and approval.

## Node Compatibility Claim

What Node version should Monja formally support across the published SDK, as
distinct from the version recorded by this example?

Recommended default: the example checks ESM and `globalThis.fetch` and records
the exact verified Node version. The generated consumer's pinned TypeScript
5.7.2 and `@types/node` 20.12.14 are deterministic proof-harness inputs, not a
claim that the SDK supports every Node 20 release. Do not add or change the SDK
package's `engines` field until Monja has a dedicated minimum-version test and
support decision.
