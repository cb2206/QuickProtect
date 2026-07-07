# Windows/Linux port — session handoff

Cross-platform .NET 8 + Avalonia + LibVLCSharp reimplementation of the macOS
QuickProtect app, living in `desktop/`. Branch: `feat/windows-linux-port`.

## Status
Feature-complete vs. the macOS app for the targeted scope (see `PARITY.md`).
Builds clean; 41 Core unit tests pass. Verified running on macOS (arm64).

## Startup crash — FIXED
**Root cause:** the app manifest (`src/QuickProtect.App/app.manifest`) was missing
the `<compatibility>` supported-OS GUID list. Avalonia's Win32 `NativeControlHost`
(used by LibVLCSharp's `VideoView`) can't create its child window without it and
throws `InvalidOperationException: "Unable to create child window for native
control host. Application manifest with supported OS list might be required."`
The crash fires when the **camera panel opens** — i.e. right after the first-run
wizard (which auto-opens the grid), and on a tray click on later launches. The
post-fetch path (PTZ login, update check, hotkey) was *not* involved.

Note the crash bypassed `crash.log`: it surfaced through the Win32 tray WndProc,
so it landed in the Windows **Application** event log (`.NET Runtime`, Event ID
1026) rather than the managed `AppDomain.UnhandledException` handler. That's where
the real stack was found:
```
powershell "Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='.NET Runtime';Id=1026} | ? Message -match QuickProtect"
```

**Fix:** added the standard supportedOS `<compatibility>` block (Win 7–11 GUIDs) to
`app.manifest`. Verified on Windows-on-ARM (x64-emulated debug build): the camera
panel now opens with no crash; 41 Core tests still pass.

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
