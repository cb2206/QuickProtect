## graphify

This project uses a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Note: graphify-out/ is **gitignored** (machine-specific generated output). It won't exist on a fresh clone — run `graphify update .` once to generate it locally. The rules below apply only when the files are present.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Repo layout

- `macos/` — the Swift/AppKit menu-bar app (XcodeGen project, fastlane, SwiftLint, asset tools).
- `dotnet/` — the .NET 8 + Avalonia reimplementation for Windows and Linux (one codebase for both).
- `docs/` — cross-platform docs: PARITY.md (feature parity tracking), PRIVACY.md, APP_STORE_LISTINGS.md, screenshots.
- `scripts/macos|windows|linux/` — per-platform `build` and `run` entry points.

## Loop protocol

Every **code change** runs as a loop, not a line. Sessions with no code changes
(brainstorming, design, planning, config review) skip this loop entirely.

1. Write the change.
2. Run the checks. For Swift changes (run from `macos/`):
   `xcodebuild test -scheme QuickProtect -destination 'platform=macOS' -quiet`,
   then `swiftlint --strict`. For C# changes: `dotnet test dotnet/QuickProtect.sln`
   (requires the .NET SDK; on this Mac it is not installed — note that in the report
   instead of skipping silently). No silencing errors with try?, try!, force-unwraps,
   or empty catch blocks.
3. If anything fails, read the error, fix the cause, go back to step 2.
4. Repeat up to 5 times.

Stop conditions:
- All checks pass: report "done" with the passing output as proof.
- 5 attempts used: stop and report what still fails and what you tried.
- Same error appears twice in a row: stop. You're guessing, not fixing.

Never report "done" without check output from this session.
Never fix a test by weakening it. Fix the code, not the test.

Hook enforcement (see .claude/settings.json):
- Editing a `.swift` file marks the session "dirty" (a `/tmp/qp-dirty-$SESSION_ID`
  marker) and runs a fast per-file lint that blocks only on **error-severity** violations.
- On Stop, if the session is dirty, the full gate runs automatically from `macos/`:
  `xcodebuild test` then `swiftlint --strict` (whole Swift project). Either failure
  blocks the stop and is fed back for fixing. A clean (non-code) session stops
  immediately with no checks.

SwiftLint baseline: macos/.swiftlint.yml disables rules the legacy code still violates.
Don't add new violations of those rules; re-enable rules as files get cleaned up.
