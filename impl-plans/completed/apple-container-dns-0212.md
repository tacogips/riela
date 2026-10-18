# Apple Container gateway DNS resolution

Issue: https://github.com/tacogips/riela/issues/146

On the tested Apple Container 1.5.0 default network, Gmail default-family DNS resolution failed before HTTP while forced IPv4 reached verified TLS and HTTP401. The guest had one link-local IPv6 address and no global-scope IPv6 address. The resolver options single-request and single-request-reopen did not fix the failure; no-aaaa did. The same native builtin and guarded Gmail0.1.21 image with synthetic credentials then returned the expected numeric HTTP401.

Add --dns-option no-aaaa only to egress-allowed Apple container gateway startup. Preserve the host DNS resolver, existing image, protected credential frame, isolation guard and cleanup. Denied networking remains --network none --no-dns. This is a workaround for the verified default network, not a universal claim about Apple IPv6 support.

Validation: 56 focused native tests, one optional skip, zero failures; four actual offline image/executor regressions passed. ART offline private-transport capability passed. Changed-file SwiftLint has only the existing test helper large_tuple warning. An independent source review approved the minimal change. One authorized real minimal Gmail profile invocation succeeded with the native0.2.12 candidate and unchanged guarded image; no message bodies or raw provider output were persisted. No additional real-account probes are needed.

Release0.2.12 must use fresh final-version CLI/DMG artifacts, signing/notarization/stapling/Gatekeeper checks, Linux clean-image smoke, public asset digest verification, and formula/cask metadata validation. Earlier immutable tags remain unchanged.
