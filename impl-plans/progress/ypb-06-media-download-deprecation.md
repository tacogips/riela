# ypb-06 implementation progress

Accepted design §E and plan align: warn only; preserve runtime behavior. Dependency ypb-03 is accepted by dispatch. The shared file fresh pre-hash matches its ypb-03 post-hash.

| Path | Pre SHA-256 | Post SHA-256 |
|---|---|---|
| Sources/RielaCore/WorkflowValidation.swift | e0be0bd4e697459ba67096459e5c1a4c2339819bbdbac7257bd250babfec0a69 | 31e28bfa78ca96a3c03b7b45266335b2d531103b6a1d3e3ec91df7499ed6e315 |
| Sources/RielaCore/WorkflowDeprecatedAddonValidation.swift | absent | ad9b374f72358368c4edd0ff1d3e957d41e2320a892fb7a23b4cdbf254e6c4d7 |
| Tests/RielaCoreTests/MediaDownloadDeprecationValidationTests.swift | absent | 4f6422139af7b5f6d15cffd9c54c805fa14e59ba771d549a09d6068e98c5477b |
| Tests/RielaCLITests/MediaDownloadDeprecationWarningTests.swift | absent | 8991634da8475ea1c66fceef37fe322d65408344a8cadf5539f0bf87f7648881 |
| impl-plans/progress/ypb-06-media-download-deprecation.md | absent | See plan-local progress-post.sha256 |

| Gate | Exit | Evidence |
|---|---:|---|
| arm64 swift build | 0 | tmp/youtube-processing-builtins/ypb-06-media-download-deprecation/build-final.log |
| arm64 focused swift test | 0, 25 tests, 0 failures | tmp/youtube-processing-builtins/ypb-06-media-download-deprecation/test-final.log |
| arm64 selected SwiftLint strict | 0, empty | tmp/youtube-processing-builtins/ypb-06-media-download-deprecation/swiftlint.log |
| shared file comparison | 1, expected one added line | tmp/youtube-processing-builtins/ypb-06-media-download-deprecation/shared-diff.log |

Initial test.log exited 1 (25 tests, 2 assertions) because the CLI fixture omitted its referenced callee; replaced it with a standalone workflow and reran. The shared comparison contains only the requested call. These gates ran on the shared moving tree; formal reviews and serial integration remain downstream.
