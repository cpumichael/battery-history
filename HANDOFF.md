# Battery History handoff

Updated September 29, 2026.

## Current state

Implemented a macOS 14+ SwiftUI menu bar app with IOKit battery collection,
embedded DuckDB storage, Swift Charts, selectable date ranges, measured drain
and charging rates, macOS time estimates, and launch-at-login settings.
Every sampled reading is retained locally. Sleep and collection interruptions
appear as chart gaps. Closing the window leaves recording running.

The implementation plan is in `PLAN.md`; build and usage instructions are in
`README.md`. The Xcode project is `BatteryHistory.xcodeproj`.

## Latest change

`AppModel.openHistory()` retains and reuses one NSWindow. That window now uses
`.moveToActiveSpace`. When summoned from another Space, it is ordered out
before being made key and ordered front. It does not use `.canJoinAllSpaces`.

The latest change is included in the release app:

```sh
open "/Users/mbarnes/src/battery-history/build/Build/Products/Release/Battery History.app"
```

Quit any older running copy before opening the updated build. If using a copy
in Applications, replace that copy with the updated build.

## Validation

- All 13 core tests passed before the latest window-only change, including
  parsing, rates, gaps, persistence, rollback, schema compatibility, crash
  recovery, and a year of 525,600 retained samples with compression inspection.
- The latest window change passed the release build and strict signature check.
- A development probe successfully read the Mac's actual battery.
- Live UI inspection timed out through the computer-use tool. The temporary
  preview process launched for validation was stopped.

## Remaining manual checks

Verify the active-Space fix with the window already open on another desktop,
closed, and minimized. Summoning should keep the current desktop active, move
the window there, and leave it absent from other desktops.

Also verify real sleep/wake and login-item behavior. The app is signed ad hoc
for local use and built for this Mac's arm64 architecture. Copy it to Applications
for reliable launch at login. Distribution signing remains outside the v1 scope.

## Development

```sh
swift test -j 4
xcodebuild -project BatteryHistory.xcodeproj -scheme BatteryHistory \
  -configuration Release -derivedDataPath build -jobs 4 build
```

DuckDB Swift is pinned to 1.1.3 in the package lockfiles. The chart query uses
segment-aware bucket aggregates to preserve extrema and transitions; a previous
multi-window-ranking query triggered a DuckDB spill assertion on a year of data
and was replaced. Batch inserts use DuckDB's Appender.

Production history is stored separately from the source and build files at
`~/Library/Application Support/Battery History/history.duckdb`.
