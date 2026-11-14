---
name: rielaapp-ui-verification
description: Verify RielaApp macOS UI changes through the current debug executable, screenshots, AppKit layout tests, and stale-bundle checks. Use when reviewing, fixing, or visually validating RielaApp windows such as Instances, workflow viewer, prompts, profile selection, Settings-style lists, iPhone-like flows, or any UI spacing/alignment issue.
---

# RielaApp UI Verification

## Core Rule

Do not trust `.build/debug/RielaApp.app` for visual verification unless its executable timestamp proves it was regenerated after the current source edit. SwiftPM can report `Build of product 'RielaApp' complete` while a previously generated `.app` bundle remains stale or missing.

Prefer running the current debug executable directly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault \
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp

.build/arm64-apple-macosx/debug/RielaApp \
  --app-root tmp/rielaapp-ui-review/app-root \
  --home-root tmp/rielaapp-ui-review/home-root \
  --project-root "$PWD" \
  --open-workflows \
  --no-autostart-daemons
```

If you intentionally run an app bundle, first check:

```bash
ls -l .build/debug/RielaApp.app/Contents/MacOS/RielaApp \
  .build/arm64-apple-macosx/debug/RielaApp
```

The bundle executable must not be older than `.build/arm64-apple-macosx/debug/RielaApp`.

## Verification Workflow

1. Stop only the RielaApp test process you started, or use `pkill -x RielaApp` when the session is explicitly using isolated test roots.
2. Use repository-root `tmp/` for all app roots, logs, screenshots, and scratch output.
3. Build `--product RielaApp`.
4. Run `.build/arm64-apple-macosx/debug/RielaApp` directly with isolated roots.
5. Capture the RielaApp window by CGWindow ID, not by screen rectangle coordinates.
6. Inspect the screenshot with `view_image`.
7. Run focused AppKit layout tests for the changed window.
8. Report exactly which executable was launched and which screenshot verified the UI.

Window-ID screenshot command:

```bash
window_id=$(swift -e 'import CoreGraphics; import Foundation; let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]; let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []; for w in windows { if (w[kCGWindowOwnerName as String] as? String) == "RielaApp", let number = w[kCGWindowNumber as String] { print(number); break } }')
screencapture -x -l "$window_id" tmp/rielaapp-ui-review/current-window.png
```

## UI Review Standard

For RielaApp macOS windows, prefer macOS System Settings conventions:

- Keep a normal content inset, usually 16-24 pt, instead of pinning controls to the titlebar.
- Keep section headers close to their rows, usually 10-14 pt.
- Avoid large blank vertical gaps between title/header and first row.
- Avoid list rows stuck to the top edge; leave enough breathing room for a native Mac settings pane.
- Use icon-only toolbar buttons with accessibility labels and tooltips.
- Verify both list and detail states when a window has drill-in navigation.

For compact/iPhone-like flows, keep the same hierarchy but check narrower window sizes and text truncation.

## Required Evidence

Before claiming a RielaApp UI issue is fixed, collect:

- A passing build or focused test command.
- A screenshot from the current debug executable.
- A note that `.build/debug/RielaApp.app` was not used, or proof that it was fresh.
