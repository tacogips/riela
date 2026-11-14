# Native Gmail SDK on Linux

Riela0.2.44 pins Gmail source4ce54035694bbcbe88c33a4de3f5905677370b0e
and links GmailGatewayCore on Darwin and Linux. Reader/draft/sender nodes await
GmailGatewaySDK.execute directly, retaining fixed roles, canonical envelopes,
explicit environment projection and the normal gateway deadline/cancellation.
This removes the embedded synchronous CLI bridge.

The SDK requires an explicitly supplied GMAIL_GATEWAY_CONFIG. Host and real-guest
metadata fixtures use a credential-free config; guest tests mount it read-only.
No gateway credential, live Gmail fetch or publication is part of this check.

Source verification:10 Gmail adapter tests including real SDK mode calls and14
gateway command tests passed; touched Swift files passed SwiftLint; diff check
passed. Gmail's separate native Linux tests and Linux amd64 CI also passed.
Actual Claude Opus5.5 reviewed the async adapter change along with the upstream
bridge; no actionable correctness issue remained.

Release publication/local CLI update and a rebuilt real guest gate are next.
ART native Gmail acquisition and the App source/guest cutover remain subsequent
work; source compilation alone does not deploy either.

The common worker-image source preparation now pins the same portable Gmail
revision directly and preserves the unconditional product dependency. Its pinned
package matcher accepts an inline revision comment while still requiring exactly
one match. The actual prepared Riela manifest passes SwiftPM dump-package;
Gmail, Analytics and Documents share GoogleGatewayAuth48e0112 and compatible
GatewaySDKKit0.1.1, while adapted crypto4.5.2 satisfies Gmail's lower bound.
Actual Opus5.5 found no actionable packaging issue. This build-tool correction
does not alter the already-built0.2.44 runtime binary. A full common-image build
is still a separate gate; it has not been claimed as executed here.
