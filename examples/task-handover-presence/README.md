# Task handover: user presence

This example pauses before publishing because authentication must happen on a host where the user is reachable. The takeover placement requires the `userReachable` host trait.

Typical task commands:

```sh
riela task run <task-id>
riela task takeover <task-id>
riela task takeover <task-id> --traits userReachable
```

Run `gh auth login` on the selected host before the trait-qualified takeover. The bundled mock run suspends at `check-login`; the task harness checks refusal and successful continuation.
