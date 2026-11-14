Read the latest outputs from the design review and implementation review steps.

Return one JSON object only with keys:
- `status`: `reviewed`
- `designAccepted`
- `implementationAccepted`
- `implementationNeedsRevision`
- `blockingFindings`
- `nextImplementationActions`
- `design`
- `implementation`
- `residualRisks`

If either prior step did not produce parseable JSON, set the relevant accepted flag to `null`, include a blocking finding explaining the missing output, and recommend rerunning the workflow after fixing the failing step.
