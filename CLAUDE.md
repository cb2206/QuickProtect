## Adversarial review

Plans and complex tasks get an independent adversarial review before they are
presented as final: a plan, an audit, a design, a multi-file or cross-platform
change, a release or dependency upgrade. Trivial edits and lookups are exempt.

- Reviewer: a separate agent on the **latest Fable model available** (check the
  model list; don't pin an older version from memory). Read-only: it verifies,
  it doesn't edit, commit or touch GitHub.
- Brief it with the plan or diff and where to verify it (files, `git`, `gh`),
  not with your conclusions, and tell it to treat every claim as unverified.
- Fold confirmed findings into the result, and say which findings were rejected
  and why. Don't present the plan as reviewed until the review has come back.

## Loop protocol

Every **code change** runs as a loop, not a line. Sessions with no code changes
(brainstorming, design, planning, config review) skip this loop entirely.

1. Write the change.
2. Run the checks. For Swift changes (run from `macos/`):
   `xcodebuild test -scheme QuickProtect -destination 'platform=macOS' -quiet`,
   then `swiftlint --strict`. For C# changes: `dotnet test dotnet/QuickProtect.sln`
   (on the Mac the .NET SDK, when installed, is user-local at `~/.dotnet`, not on PATH:
   `export DOTNET_ROOT=$HOME/.dotnet PATH=$HOME/.dotnet:$PATH`; without it, C# changes
   can only be verified by the `dotnet` CI workflow). No silencing
   errors with try?, try!, force-unwraps, or empty catch blocks.
3. If anything fails, read the error, fix the cause, go back to step 2.
4. Repeat up to 5 times.

Stop conditions:
- All checks pass: report "done" with the passing output as proof.
- 5 attempts used: stop and report what still fails and what you tried.
- Same error appears twice in a row: stop. You're guessing, not fixing.

Never report "done" without check output from this session.
Never fix a test by weakening it. Fix the code, not the test.
