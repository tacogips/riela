# Expected results

A one-time `riela workflow run` completes using the authored files. The
`improve-context` add-on returns `skipped / oneTimeRun`; its false `improvable`
route goes directly to `workflow-output`, and no definition rows or CLI apply
are created.

In service mode, run 1 seeds a pinned definition and reports no previous run.
Run 2 reads the bounded digest of run 1, applies the mocked prompt patch through
`riela workflow definition update`, and records an audit with actor kind
`improvementNode`, the mocked reason, and session/step execution evidence. Run
3 uses the updated stored prompt while the example files remain unchanged.
