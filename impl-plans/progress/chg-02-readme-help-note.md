# chg-02-readme-help-note progress (#184)

Implemented the accepted GC2/D5 README help note after the SurfaceCatalog paragraph. No existing README lines were changed.

- Before SHA-256: `d4943a7646ddd2f6c0a2ab02cf5a17bd3f3124483c282908c1d76a1f47f1cb51`
- After SHA-256: `deff0622f72243b0be69d851c8f244bb5594598e6bf276d3ff432bf82d89e167`

Inserted paragraph:

> `riela <command> [<subcommand>] --help` (or `-h`) prints usage on stdout
> and exits 0 before required arguments are checked. Tokens after `--` belong to
> the child program or workflow and are never help requests; pass a literal
> `--help` option value as `--option=--help`. `riela gateway <name> --help`
> shows the linked gateway's own help.

| Gate | Exit | Log |
| --- | ---: | --- |
| README diff numstat: 6 added, 0 deleted | 0 | `tmp/issue-184-gap/chg-02-readme-help-note/diff.log` |
| Help examples grep | 0 | `tmp/issue-184-gap/chg-02-readme-help-note/grep.log` |
| Protected paths diff: empty | 0 | `tmp/issue-184-gap/chg-02-readme-help-note/protected-paths.log` |
| Section placement and diff assertions | 0 | `tmp/issue-184-gap/chg-02-readme-help-note/structural-check.log` |

Implementation criteria are complete. Formal review and Git finalization belong to subsequent workflow steps. No Swift build is required for this documentation-only plan.
