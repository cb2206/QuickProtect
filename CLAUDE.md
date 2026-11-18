## Loop protocol

Every **code change** runs as a loop, not a line. Sessions with no code changes
(brainstorming, design, planning, config review) skip this loop entirely.

1. Write the change.
2. Run the checks. For Swift changes (run from `macos/`):
   `xcodebuild test -scheme QuickProtect -destination 'platform=macOS' -quiet`,
   then `swiftlint --strict`. For C# changes: `dotnet test dotnet/QuickProtect.sln`
   (on this Mac the .NET SDK is user-local at `~/.dotnet`, not on PATH:
   `export DOTNET_ROOT=$HOME/.dotnet PATH=$HOME/.dotnet:$PATH`). No silencing
   errors with try?, try!, force-unwraps, or empty catch blocks.
3. If anything fails, read the error, fix the cause, go back to step 2.
4. Repeat up to 5 times.

Stop conditions:
- All checks pass: report "done" with the passing output as proof.
- 5 attempts used: stop and report what still fails and what you tried.
- Same error appears twice in a row: stop. You're guessing, not fixing.

Never report "done" without check output from this session.
Never fix a test by weakening it. Fix the code, not the test.
