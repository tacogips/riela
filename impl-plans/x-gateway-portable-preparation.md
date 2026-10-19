# Portable X gateway container preparation

The container preparer must accept the public X gateway's older unadapted source,
an already prepared copy, and0.1.14's native Linux portability fix. Accept only
known import/fallback shapes, validate all anchors before writing, and reject
mixed/unknown source drift. Repeated preparation must not duplicate imports.

The container default revision advances to public2ffa0d9b5231574f3811b55b7d5a57f6f641e3f0.
The host SDK dependency and runtime caller configuration are outside this change.

Verification: scripts/tests/test_prepare_x_gateway.py plus actual public0.1.13
and0.1.14 source-copy idempotency probes. X0.1.14 raw Linux amd64 CI passed.
A uniquely tagged container image must pass an offline native-node gate before
any caller switches its image. No current ART image is changed by this source fix.
