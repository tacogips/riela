# sac-08 implementation progress

Implementation complete; formal review and combined-tree integration remain downstream.
The accepted design selects channel mode without `--server` and preserves explicit HTTP.
The seven new cases cover operations, rendering, conflicts, 422, lock outcomes and HTTP selection.
Existing RuntimeEnvironmentChannelTests changes append only `--server http://127.0.0.1:8787` to five invocations; see `tmp/serverless-app-control/sac-08-cli-environment-local-mode/existing-test-diff.log`.

Private scratch seed `[ -d tmp/serverless-app-control/build-sac-08/checkouts ] || { mkdir -p tmp/serverless-app-control/build-sac-08 && cp -cR .build/. tmp/serverless-app-control/build-sac-08/; }`: exit 0. Copied module cache contained stale absolute paths; attempts 1 and 2 failed, then only the private copied ModuleCache was removed. Attempt 3 exposed a source compile error fixed before final build. Logs retained in `tmp/serverless-app-control/sac-08-cli-environment-local-mode/`.

- `arch -arm64 /bin/zsh -lc 'swift build --scratch-path tmp/serverless-app-control/build-sac-08 --build-tests'`: exit 0, `build.log`, SHA-256 `118d8e2a016d6f984af3857df9bee6fdbb1d1aaacaed66cec0b3bb7e54a4544c`.
- `arch -arm64 /bin/zsh -lc "swift test --scratch-path tmp/serverless-app-control/build-sac-08 --skip-build --filter 'EnvironmentLocalModeTests|RuntimeEnvironmentChannelTests|ServeWebHostRuntimeEnvironmentTests'"`: exit 0, 21 tests, 0 failures, `test-final.log`, SHA-256 `df2f627c9af14c1eddcfe2d996ac1478f65079ac5cee5d878034246256d021e7`.
- Strict selected-file SwiftLint through `changed-swift.nul`: exit 0, `lint-final.log` (empty).

Source SHA-256: EnvironmentCommand `422511a3824913dbb9493add3be3bbf689c305c3a5213a713a207578446feb75`; EnvironmentLocalModeTests `af5c8528f16643a80454afe73b1486c8d1deacf267e8173fa1b07a970e5a50a7`; RuntimeEnvironmentChannelTests `f3acc7ec4a1ce3f64377cb72e0fef7992bb9776a061a8b302ae0438292d8218c`.
