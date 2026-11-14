# Task handover: answer

This example pauses after preparing a deployment plan and asks the user to choose `staging` or `production`. The successor resumes at `apply`, using the recorded answer and imported plan history.

Typical task commands:

```sh
riela task run <task-id>
riela task answer <task-id> --question q-deploy-target --json '{"option":"staging"}'
riela task takeover <task-id>
```

The bundled mock run suspends at `plan`; the task harness verifies answer delivery and completion.
