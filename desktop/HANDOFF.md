# Windows/Linux port — session handoff

Cross-platform .NET 8 + Avalonia + LibVLCSharp reimplementation of the macOS
QuickProtect app, living in `desktop/`. Branch: `feat/windows-linux-port`.

## Status
Feature-complete vs. the macOS app for the targeted scope (see `PARITY.md`).
Builds clean; 41 Core unit tests pass. Verified running on macOS (arm64).

## Open bug we're chasing (why this handoff exists)
On **Windows 11 on ARM**, running the **x64** self-contained build (under x64
emulation), the app **crashes** shortly after the first-run wizard, and on later
launches it crashes a few seconds in **without opening the camera panel**. This
is *not* the macOS libVLC crash (already fixed) — it's something in the
post-fetch startup path (PTZ classic-login, update check, or global-hotkey
registration), or an artifact of x64-on-ARM emulation.

A crash logger is in place: fatal exceptions are appended to
`%APPDATA%\QuickProtect\crash.log`.

### First thing to do in the VM
1. Build & run **natively (arm64)** to rule out emulation:
   ```
   cd desktop
   dotnet run --project src/QuickProtect.App
   ```
2. Reproduce the crash, then read `%APPDATA%\QuickProtect\crash.log` — it has the
   exact exception + stack. Fix the root cause from there.

## Notes for running on Windows on ARM
- **Native arm64**: there is no arm64 libVLC NuGet, so video won't initialize and
  the app runs **without video** (graceful — tiles show "Video unavailable").
  That's fine for debugging the startup crash. For video on arm64, install VLC
  for Windows ARM and point libVLC at it (same approach as macOS in `Program.cs`).
- **x64 emulated**: `dotnet run -r win-x64` (or the published self-contained build)
  bundles x64 libVLC and gets video, but runs under emulation.

## Build / test / publish
```
cd desktop
dotnet build QuickProtect.sln                 # build all
dotnet test tests/QuickProtect.Core.Tests     # 41 tests
dotnet publish src/QuickProtect.App -c Release -r win-arm64 --self-contained   # native package
```

## Layout
- `src/QuickProtect.Core` — portable: models, `ProtectService` (UniFi dual API),
  `CertificateTrust` (TOFU pinning), `AppSettings`, secret/prefs stores. Unit-tested.
- `src/QuickProtect.App` — Avalonia UI: tray shell (`App.axaml.cs`), camera grid
  (`MainWindow` + `MainViewModel`/`CameraTileViewModel`), focus view + PTZ,
  pinned windows, settings, onboarding, localization.
- See `git log --oneline` for the feature-by-feature build-out.
