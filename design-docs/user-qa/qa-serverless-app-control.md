# User QA: server-less RielaApp control

Design: `design-docs/specs/design-serverless-app-control.md`.

## Q1. In-process `instance run` without a running App

The request allows `instance run` to run the instance's stored definition
inside the CLI process, but only behind an explicit flag. The design leaves
this flag out, so with no App running, `instance run` returns
`app_not_running` (§3.9).

Such a run would use the CLI's own process environment. It would not have the
credentials RielaApp keeps in memory, and it would bypass the App's overlap
policy and the child admission gate.

Default if unanswered: no flag. Add one later only with an accepted credential
source and an acceptance test.

## Q2. Env var for server mode

The design adds no env var. Only `--server <url>` selects HTTP mode (§3.1).

Should a `RIELA_APP_SERVER` env var be added for scripts that always target a
remote host? Default if unanswered: no.
