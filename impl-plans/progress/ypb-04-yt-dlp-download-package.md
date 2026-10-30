# ypb-04 implementation progress

Status: blocked, incomplete. The accepted plan assumes `riela package install` projects workflow package add-ons into the shared store, but `installSharedAddonProjections` is invoked only by `Sources/RielaCLI/NodeCommandRunner.swift`. The focused test confirms the projection is absent. Repair needs an authorized package-install source path and integration decision. Resume after ownership is amended and projection is implemented; do not weaken the test.

All owned files were absent before creation (pre SHA-256: absent). Post SHA-256:

```
23fa51151e5873e3fae95fc5bdbeb561658218eaede594eddcf22e522ccea9ff  examples/video-pipeline-yt-dlp/README.md
e7b9eb195be949caea7a7107f74a062c897c7eba0872ae773943df1f2b38f456  examples/video-pipeline-yt-dlp/riela-package.json
9eb24db94c4f10d329b4f5f4ed28ad5ffdaad92ce5f5c59368a64f56457bebfe  examples/video-pipeline-yt-dlp/addons/yt-dlp-download/Containerfile
f7124f68a7d908073bd9a34e1e14a1e28ab5b83c96806140b2d80bea6b2b04c0  examples/video-pipeline-yt-dlp/addons/yt-dlp-download/yt-dlp-download
e0f4ec080dd9aec931c4b2ba2c915c908d1f5b198f76fb95642e9e4c726bafa2  examples/video-pipeline-yt-dlp/workflow/mock-scenario.json
4f012e3eec9fd302f678f03dd6685bedd070c8c8b22d2c5f739f7f137bb6050a  examples/video-pipeline-yt-dlp/workflow/workflow.json
118b5619aa5f675ff07024240df43c40d93b4bb42203bea1db0c714d2920346d  Tests/RielaCLITests/VideoPipelineYtDlpPackageTests.swift
```

Per-edit intent and pre-edit snapshot: `tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/edit-intent-{1,2,3,4,5}.txt` and `script-before-4.txt`. Digest: SHA-256 of `cat addons/yt-dlp-download/Containerfile addons/yt-dlp-download/yt-dlp-download`; checksum: Python implementation of `WorkflowPackageChecksum.md5`, sorted paths and bytes excluding manifest, in `tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/create.py` (refresh code for final edit in edit command evidence). Package validates after refresh.

| Gate | Exit | Log |
| --- | --- | --- |
| swift build, initial | 1 | tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/build.log (sibling DurableQueue compile errors) |
| swift build, final | 0 | tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/build-final.log |
| swift test --filter VideoPipelineYtDlpPackageTests | 1, 2 tests, 1 failure | tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/test.log |
| package validate | 0 | tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/package-validate.log |
| selected SwiftLint strict | 0, empty | tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/swiftlint.log |
| no top-level workflow | 0 | tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/no-top-level.log |
| find __pycache__ | 0, empty | tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/pycache.log |

Remaining: implement fake-tool tests for success, caching, live and duration rejection, and assert mock path propagation and both scope projections. Re-run final focused test. Review URL normalization and error-stage diagnostics against the plan. Formal reviews and finalization are downstream.

## Integration repair INT-W1-H1

The prior blocker is superseded: package install installs the package in each scope; node install projects its add-on to the shared store. The README and focused tests now reflect those separate operations. The focused test checks the actual audio input snapshot and exercises a copied script with fake tools for success, cache, live, duration and private-address rejection. Formal review remains downstream.

| File | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| Tests/RielaCLITests/VideoPipelineYtDlpPackageTests.swift | 118b5619aa5f675ff07024240df43c40d93b4bb42203bea1db0c714d2920346d | f5f157c730d40091024c3251e7321fefa1217b39e97d37c071032f749a0d9445 |
| examples/video-pipeline-yt-dlp/README.md | 23fa51151e5873e3fae95fc5bdbeb561658218eaede594eddcf22e522ccea9ff | e47347fa6937f397153c03ff642136e5ee306906613c8e7b36e0c349eaf647f4 |
| examples/video-pipeline-yt-dlp/riela-package.json | e7b9eb195be949caea7a7107f74a062c897c7eba0872ae773943df1f2b38f456 | 2d8a88a207b711f07a7dca42f3b67c13d9b774d9a28d81111a7c04e3bb9fa6ef |
| progress log | 2918708023358de36be05440adfae23e9868b4481ae7741d2fc1f513a05a1695 | recorded separately in r2-progress-post.sha256 |

Checksum refreshed using the sorted path and bytes MD5 recipe in create.py. Evidence directory: `tmp/youtube-processing-builtins/ypb-04-yt-dlp-download-package/`.

| Gate | Exit | Log |
| --- | --- | --- |
| Package validate | 0, valid | package-validate-r2.log |
| Strict selected SwiftLint | 0, empty | swiftlint-r2-final.log |
| Layout check | 0, empty | layout-r2.log |
| Build | 0 | build-r2-final.log (before final test decoder correction); build-r2-current.log verifies current source |
| Focused test | 0, 2 tests, 0 failures | test-r2-final.log |
| Strict lint after decoder correction | 0, empty | swiftlint-r2-current.log |

The earlier test-r2.log had one owned date-decoding failure; corrected with ISO 8601 decoding and superseded by test-r2-final.log.
