# bots-20-web-management progress

Workflow mode `issue-resolution`. Checkpoint `fcd006da53cf39864b7ea9ef948a7e30a8222715`.
The operator-approved manifest and active plan are the accepted scope. Runtime dispatch accepted `bots-19-remote-surfaces`.
No GitHub issue. Scope derives from `fable-sol-design-and-implement-review-loop-session-1` (design `comm-000004`, plans `comm-000008`).

## Implemented

- Bots uses a persistent left list and a selected detail pane at desktop widths. The 620px breakpoint switches between the panes. The index selects the first active, actionable bot.
- Active board titles link to the workflow run hash. The Activity button opens the separate long-poll pane. Bot and paired-run links preserve remote identity.
- The shared host switcher updates the server registry and keeps only a host name in session storage. All-host reads use individual named requests, preserving results from healthy hosts when a grant fails. Disconnected rows show last seen and carry no actions.
- Bot detail includes the Markdown editor, latest-20 history and undo, open suggestions, job schedules and Run now, and session corrections. Bot create/edit uses the model catalog and accepts custom model IDs.
- Models lists instance probe, authentication and catalog details. Refresh, add and remove use the selected or owning host.

## Per-edit hashes

Every intent includes the exact hunk and its before and after SHA-256 in `tmp/bots-overview/bots-20-web-management/edit-intentions.md`. The table gives pre-node and final source hashes.

| Path | Before | After |
| --- | --- | --- |
| `web/src/App.test.ts` | `80a5c3a694736e0699b82f2241b3f64e4bad3edf481665279eb85ae342871594` | `1f0c8f68d49042c5b8bd01db134473daf8bed841345e1916e3de40e3b2feb84b` |
| `web/src/App.tsx` | `662cf22e7a72a9fe28e7e91a3e0425e415d659fd9fb7b80e4377dbb4054c0e68` | `9b2b875cfd7cba7f4b00807f2050f64da6b657b99abda7b7b7478251525f365a` |
| `web/src/bots/BotDetailView.tsx` | `a81d6040a5e9482fdcbb12a4d0967c8f89acc56ef5c7af4f6ee383af03bda1a5` | `f9e2aed91d0750fdb0f920f81788f4f50a49dc0ae5ebcf8e82dddb88ef0dbc3d` |
| `web/src/bots/BotForm.tsx` | `absent` | `09d0c63fe0403827e3e294551579323285105cccb89132136ed0ae2cc5572e0a` |
| `web/src/bots/BotMemoryPanel.tsx` | `absent` | `1e148dad010720d9d3bedc90bba43054ebb3af771075a82779747b7590e166ed` |
| `web/src/bots/BotSuggestionsPanel.tsx` | `absent` | `2be5f5976fc47a8792ef3e1cdb2dae6ef7f0089f7c0abee0e660340aec27130c` |
| `web/src/bots/BotsView.tsx` | `c9fe51d100341f1bf98a19dc67ad26146c0ca53e4cbb04b56010156bc65c7b8b` | `273210d6ca8ec7ae4d2414ef7077ea765027e0d2c86480c69fde67dfc394f1d1` |
| `web/src/bots/RemoteSwitcher.tsx` | `absent` | `7bb23cf18a7afc4e364b7bf7367ec46134cadce252e5f370d62c90aa0a16f4a6` |
| `web/src/bots/activityFeed.test.ts` | `3e37a7f6f82052860d46bd15a3f44ad53172b85b75c2b7b4dfb29ff89222d16c` | `1ee5af80e7550c8aa24eccfd19e34993d91d4389bd367a14c054d7b164ccd426` |
| `web/src/bots/activityStream.test.ts` | `b595ba8a6edd0e65ba28e4100d999711763ca1be5d2b2f450851fad788d64c64` | `522c4baec06c9f4a40af626abbad1ed6896f1c95fc609536eb9900aead7e5468` |
| `web/src/bots/boardView.remote.test.ts` | `absent` | `e89d7fa2d7d6043a57ce3679be242ad6e3c73c6451e032f4ed4946fc967bc64e` |
| `web/src/bots/boardView.ts` | `e2e5e870970c2be715f24e13f7a26c6e53a80fff464f6a265c1b6e5120d90a49` | `e508b7bde2251636b9ea2173cb16fce68255ca52960d5526c555c2c8901aeca7` |
| `web/src/bots/bots.css` | `b6058adeeeaf057e59b491f560e106a6fb46a623323e4dc0c8821fb1b4ad3199` | `5a885606461cac873bff70e122628e84b1f3d558c7ee3ee11b966371b0d02f6e` |
| `web/src/bots/client.remote.test.ts` | `absent` | `89b127d1323c165ca70ca6d737bf7ed9aab6ed9d5c9581204d43a2715c4cfa5c` |
| `web/src/bots/client.test.ts` | `68ad29bf2aca7e303c3a99ea33fcc3c3a8622e0c87c9520fb8082164d74a35b6` | `c7b1b76ba565a212ea68642b67252460385a9064ee740718d05b539602b00271` |
| `web/src/bots/client.ts` | `c54c5ab82d644438b645f4f6fbbf0efb8bc7d30e74b3ca7e327f776236440c15` | `8fe9e616b32c556eb1f431f26dc53564616a76af13215a459b55f816a44245f8` |
| `web/src/bots/contracts.ts` | `ef7fc487ab7b59d7c57c83d651bbb8ac306a458c15296895d9289aea06a59e24` | `50a9ab60c28b7152f590c2092d7811c5263d76b717cc12fce68d57719d5c653d` |
| `web/src/bots/memoryPanel.test.ts` | `absent` | `e0308381259d66658c4265495adbb81d9a4cd6bb6e6fa2bf63d0a9a07496ba07` |
| `web/src/bots/memoryPanel.ts` | `absent` | `c98cd19ffd50194a3e11bffb62385d07ea7d3cfaa87d1655bdf19bd816709f43` |
| `web/src/bots/remoteSelection.test.ts` | `absent` | `abc7f673132979c6087c6591ee59a200681c31b7ae71f483ec9811b2eecccee5` |
| `web/src/bots/remoteSelection.ts` | `absent` | `522db03ed2cf9878efb105d7ea702061aa81a948bd7d484c512739288521e290` |
| `web/src/models/ModelsView.tsx` | `absent` | `1a237c241597581e2184fb7206165c71f00890f27ce60dd27496583adf7c4f9c` |
| `web/src/models/contracts.ts` | `absent` | `f4786a70248bd8b59a9250a2cd100bb8fffef10eb119903146ec400ef20205b2` |
| `web/src/models/modelsView.test.ts` | `absent` | `af94ea2e3fcb725d96719f2c8a85be902130a23ba5e33cf2e93d07e18ac30977` |
| `web/src/models/modelsView.ts` | `absent` | `969460f17e186495bf9a80740b02b1afa7b686b37270cde70d4583cc625033e0` |
| `web/src/ops/OpsRunView.tsx` | `9e2463658cd92f99821301360dc7f9564d254ced66afe91b17c435c283ec6e3e` | `7bfe229efa3105f4d4ba3e4a1da9aca0a80647f76261e39ad4723273b9dc9024` |
| `web/src/profileViewState.ts` | `4a96e431befbe60ce9d3475404163f068f1694faad5a3307de821fc3d4a66067` | `a5ce5f1c3e407b3183709381652a419b772b8855b546cc6069ba2a09da1c4000` |
| `web/src/routes.test.ts` | `de9a9ffa3153c7703059fc11746eec4bbcce41acb6d1445038b4f15f1b416289` | `4f64a18323f6c9df226000aa0a2d8c2d6803b4e98ad3d645b76636f56c3e4030` |
| `web/src/routes.ts` | `352f95760e9b2a245885f93e27723236e87642ce3b56e0b95b93e4b635f3fd29` | `a574b0c97ba95a2e8a0bfa7a2f06d2a1931d729d69406124434476f7edadbe3e` |

## Verification

Bun version `1.4.4`. Frozen install exited 0 and changed no packages. Package and lockfile status output was empty.
The complete test log records 146 passed and 0 failed. The Chromium check exercises the production bundle with controlled GraphQL responses and reports 3 passed and 0 failed.

| Command | Exit | Full log | Tests |
| --- | ---: | --- | --- |
| `mkdir -p tmp/bots-overview/bots-20-web-management` | 0 | `tmp/bots-overview/bots-20-web-management/mkdir.log` | 0 run, 0 failed |
| `bun --version` | 0 | `tmp/bots-overview/bots-20-web-management/bun-version.log` | 0 run, 0 failed |
| `(cd web && bun install --frozen-lockfile)` | 0 | `tmp/bots-overview/bots-20-web-management/install.log` | 0 run, 0 failed |
| `(cd web && bun run typecheck)` | 0 | `tmp/bots-overview/bots-20-web-management/typecheck.log` | 0 run, 0 failed |
| `(cd web && bun run test)` | 0 | `tmp/bots-overview/bots-20-web-management/test.log` | 146 run, 0 failed |
| `(cd web && bun run lint)` | 0 | `tmp/bots-overview/bots-20-web-management/lint.log` | 0 run, 0 failed |
| `(cd web && bun run build)` | 0 | `tmp/bots-overview/bots-20-web-management/build.log` | 0 run, 0 failed |
| `git status --short web/package.json web/bun.lock` | 0 | `tmp/bots-overview/bots-20-web-management/lockfile.log` | 0 run, 0 failed |
| `grep -rn "localStorage\\|console.log" web/src/bots web/src/models; scan_status=$?; [ "$scan_status" -eq 1 ]` | 0 | `tmp/bots-overview/bots-20-web-management/forbidden-text.log` | 0 run, 0 failed |
| `git diff --check` | 0 | `tmp/bots-overview/bots-20-web-management/diff-check.log` | 0 run, 0 failed |
| `RIELA_TEST_CHROMIUM="$HOME/Library/Caches/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell" bun test tmp/bots-overview/bots-20-web-management/browser.test.ts` | 0 | `tmp/bots-overview/bots-20-web-management/browser.log` | 3 run, 0 failed |

The forbidden-text command requires grep exit 1 and empty output. The wrapper exits 0. Earlier TypeScript, test resolution, and Chromium executable discovery attempts are retained in the evidence directory. Final-source reruns passed.

## Deviations

- Paired run links render through OpsRunView using the forwarded activity projection. The graph and full execution evidence come from a host-local endpoint for local runs.
- Named read requests isolate per-host authorization errors in All. The provider or bot lists on reachable hosts remain usable.

## Completion criteria

- [x] Models, memory, suggestions, job controls and remote management.
- [x] Desktop and compact master-detail navigation and separate board activity.
- [x] Board-route regression, full web suite, typecheck, lint and bundle build.
- [x] Empty forbidden-text scan and clean package/lockfile status.

## Open items

- Formal test-integrity, adversarial and serial integration review, including cumulative Swift and remaining final gates.
- W6-U1 route parity remains covered by the accepted predecessor evidence. The route is declared at `Sources/RielaAppSupport/RielaWebAPIRouteTable.swift:163` and both parity assertions passed in `tmp/bots-overview/bots-19-remote-surfaces/cumulative.log:1215` through line 1218.
