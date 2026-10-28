# chg-02-readme-help-note: document the uniform `--help` rule in the README (#184 GC2)

```json
{
  "planId": "chg-02-readme-help-note",
  "planPath": "impl-plans/active/cli-subcommand-help-gap-02-readme-help-note.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "README.md",
    "impl-plans/progress/chg-02-readme-help-note.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Issue #184 made `--help`/`-h` behave the same way for every subcommand. This
landed on `main` at `dd6c94c9`. Only
`design-docs/specs/design-cli-subcommand-help.md` describes the rule.

Design §6.2 GC2 and decision D5 require one short user-facing paragraph in
`README.md`, under `## Control Surfaces` (README.md:1405). It goes right after
the first paragraph, the one about `SurfaceCatalog` and the five gate tests,
which ends "...silently be missing from the others.", and before the paragraph
that starts "The GraphQL schema is generated...".

## Non-goals

- Do not change `rielaCLIHelpText` or anything under `Sources/` (D5).
- Do not edit any other README section, any heading, or the table of contents.
- Do not edit the design doc, `VERSION`, `Package.swift` or any test.
- Do not document per-command help output, and do not list every command.

## File-level change

Insert exactly one new paragraph of plain prose, at most 7 lines wrapped near
80 columns like the surrounding text, at the location above. It must state
these four facts and nothing more:

1. `riela <command> [<subcommand>] --help` (or `-h`) prints that command's
   usage on stdout and exits 0. It does this before any required argument is
   checked, so `riela session status --help` works without a session id.
2. Tokens after a `--` terminator are never treated as a help request. They
   belong to the child program or workflow.
3. To pass a literal `--help` as an option value, use the
   `--option=--help` form.
4. `riela gateway <name> --help` shows the linked gateway's own help.

Style: match the neighbouring paragraphs, which use backticked commands, no
bullet list, no new heading and no emojis.

## Pitfalls

- Insert the paragraph. Do not replace an existing one. The paragraph count
  in the section goes up by exactly one.
- Keep one blank line before and after the new paragraph.
- Do not claim that `kaiba`, `routine` or `version` print command-specific
  usage. They print the full top-level help (design D2), so do not mention
  them at all.
- Do not reformat or re-wrap any existing lines.

## Edit discipline

The working tree is shared with chg-01, which edits only
`Tests/RielaCLITests/SubcommandHelpApplicationTests.swift`.

- Before the edit, read `README.md` fresh and record its SHA-256.
- Write a one-line intent note to `tmp/issue-184-gap/chg-02/intent.txt`.
- After the edit, record the new SHA-256.
- If the file changed in between, re-read it and reapply the edit.
- No git operations: no commit, stash or checkout.

## Verification

Run from the repository root. Put all logs under `tmp/issue-184-gap/chg-02/`.

1. `git diff --numstat -- README.md > tmp/issue-184-gap/chg-02/diff.log; echo "exit=$?"`
   -> 0 deleted lines and 7 or fewer added lines (counting the blank
   separator).
2. `grep -n -e "--option=--help" -e "riela gateway <name> --help" README.md > tmp/issue-184-gap/chg-02/grep.log; echo "exit=$?"`
   -> `exit=0`, and both matches lie between `## Control Surfaces` and
   `## Install`.
3. `git diff --name-only -- Sources VERSION Package.swift` -> empty.

No Swift build is needed, because this plan changes no Swift source.

## Done criteria

- `README.md` has one new paragraph in `## Control Surfaces` that states the
  four facts above, and no other README line changed.
- Verification 1-3 meet their expected results, with the log paths recorded.
- `impl-plans/progress/chg-02-readme-help-note.md` records:
  - a summary;
  - the before/after SHA-256 of `README.md`;
  - the inserted paragraph text;
  - a table of gate, exit code and log path.
