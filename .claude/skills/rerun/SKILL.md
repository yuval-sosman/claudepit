---
name: rerun
description: Kill any running ClaudepitApp instances, rebuild, and launch the latest binary. Use when asked to rerun/restart/relaunch the app, or to see the latest changes running.
---

# Rerun ClaudepitApp

Kills all running instances (stale windows are the #1 cause of "I see no
change"), rebuilds, and launches the fresh debug binary.

Run this one command:

```bash
pkill -9 -f ClaudepitApp; sleep 1; swift build --product ClaudepitApp && .build/debug/ClaudepitApp &
```

If the app still shows no changes after a successful build, SwiftPM's cache is
stale (it prints "Build complete" but the binary's mtime doesn't advance).
Force a clean rebuild:

```bash
pkill -9 -f ClaudepitApp; sleep 1; rm -rf .build && swift build --product ClaudepitApp && .build/debug/ClaudepitApp &
```

Notes:
- `pkill` first — old instances keep their window on screen and hide your changes.
- Use `--product ClaudepitApp` not `--target` — this produces the binary at `.build/debug/ClaudepitApp` via the symlink.
- Do NOT use bare `swift build` — it also builds Splash's `SplashImageGen` which fails on CLI toolchain (no CoreGraphics).
- The trailing `&` detaches the app so it doesn't block. If launching from an agent session (where a GUI launch would hang), stop after `swift build --product ClaudepitApp` and tell the user to run `! .build/debug/ClaudepitApp`.
- Release build instead: `pkill -9 -f ClaudepitApp; swift build -c release --product ClaudepitApp && .build/release/ClaudepitApp &`
