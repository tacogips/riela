# Expected Results

Use the session store passed to the run command, and capture the root session id from the run output:

```bash
export RIELA_SESSION_STORE="$PWD/tmp/issue-sweep-2-20261024/isw2-74d/store-final"
export BRAIN_SESSION_ID='brain-generated-workflow-loop-session-1'
riela session status "$BRAIN_SESSION_ID" --output json
riela session export "$BRAIN_SESSION_ID" --output json
```

The root status/export must show status `completed`, root output `decision` equal to `finish`, and exactly three brain executions. The export contains two delivered `dynamicWorkflowResult` messages with outcomes `completed`, iterations 1 and 2, and distinct child session ids and definition digests.

Export and inspect each child session named by those two result messages:

```bash
export INVENTORY_SESSION_ID='<childSessionId from iteration 1>'
export VERIFY_SESSION_ID='<childSessionId from iteration 2>'
riela session status "$INVENTORY_SESSION_ID" --output json
riela session export "$INVENTORY_SESSION_ID" --output json
riela session status "$VERIFY_SESSION_ID" --output json
riela session export "$VERIFY_SESSION_ID" --output json
```

Each child status/export must report `parentSessionId` and `rootSessionId` equal to `$BRAIN_SESSION_ID`. The inventory export's root output has `missingVerification` equal to `checksum-of-fixture-a`; the verify export's input snapshot has `input.missingVerification` equal to that same value. The root export's iteration results carry the generated workflow ids and digests for the corresponding child ids.

These are the exact commands used for this run (using the generated child ids directly):

```bash
RIELA_SESSION_STORE="$PWD/tmp/issue-sweep-2-20261024/isw2-74d/store-final" riela session status brain-generated-workflow-loop-session-1 --output json
RIELA_SESSION_STORE="$PWD/tmp/issue-sweep-2-20261024/isw2-74d/store-final" riela session export brain-generated-workflow-loop-session-1 --output json
RIELA_SESSION_STORE="$PWD/tmp/issue-sweep-2-20261024/isw2-74d/store-final" riela session status nested-v1-92734dd40581599f5544eb68c7d3653c38167b5a8bf9f72076ae566c5dfac246 --output json
RIELA_SESSION_STORE="$PWD/tmp/issue-sweep-2-20261024/isw2-74d/store-final" riela session export nested-v1-92734dd40581599f5544eb68c7d3653c38167b5a8bf9f72076ae566c5dfac246 --output json
RIELA_SESSION_STORE="$PWD/tmp/issue-sweep-2-20261024/isw2-74d/store-final" riela session status nested-v1-6e3eec560ecd4a261d880350b9f649d4102efa9762270e52952f6901669560cc --output json
RIELA_SESSION_STORE="$PWD/tmp/issue-sweep-2-20261024/isw2-74d/store-final" riela session export nested-v1-6e3eec560ecd4a261d880350b9f649d4102efa9762270e52952f6901669560cc --output json
```
