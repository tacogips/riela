# Matrix Chat Reply Sample

This sample receives text messages from an Element/Matrix room through the
`matrix` event source and sends a reply back to Matrix with
`riela/chat-reply-worker`.

Run the live local Synapse verification:

```bash
./examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh
```

The script starts Synapse with Docker Compose, creates two local users, creates
a room, starts `riela events serve`, sends an Alice message and a UTF-8 text
attachment, and waits for both riela bot replies. It also verifies the
downloaded attachment and bounded Matrix room-history artifacts.

Stop the local homeserver when finished:

```bash
docker compose -f ./examples/matrix-chat-reply/local-synapse/compose.yaml down
```
