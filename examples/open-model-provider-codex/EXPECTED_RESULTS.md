# Expected Results

## Validate

```bash
riela workflow validate open-model-provider-codex --workflow-definition-dir ./examples
```

Expected: the workflow is valid. The node uses canonical `providerProxy`
spelling and passes the loopback-only HTTP URL policy.

## Run

Start an OpenAI-compatible server at `http://localhost:8000/v1`, then run:

```bash
riela workflow run open-model-provider-codex \
  --workflow-definition-dir ./examples \
  --output json
```

Expected: codex-agent launches with `model_provider=local_vllm` and the
matching `model_providers.local_vllm` configuration. No credential is needed
for this local example; production providers should use `apiKeyEnv` rather
than inline secret values.
