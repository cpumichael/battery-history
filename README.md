# Battery History

A native macOS menu bar app with battery history that stays on your Mac.

## Build and run

Requires macOS 14 or later and Xcode with Swift 5.9 or later.

Open `BatteryHistory.xcodeproj`, select the **BatteryHistory** scheme, and Run.
The app appears in the menu bar; choose **Open History…** to see the chart.

For a UI preview with synthetic readings in a temporary database, launch the
built app with `open -n "build/Build/Products/Debug/Battery History.app" --args --preview`.
Preview mode does not collect real readings or register a login item.

To build a locally signed app from the terminal:

```sh
xcodebuild -project BatteryHistory.xcodeproj -scheme BatteryHistory \
  -configuration Release -derivedDataPath build -jobs 4 build
open "build/Build/Products/Release/Battery History.app"
```

For reliable launch at login, copy the built app to Applications and launch it
there. Settings includes a login toggle and reports when macOS requires approval.
The default signing is ad hoc for local use; distribution requires your own
signing configuration. No database server or Homebrew dependency is required.
Builds target the current Mac's architecture rather than producing a universal app.

## Behavior

- Records the internal battery once a minute while awake and on power changes.
- Keeps every sample, including unchanged values, in embedded DuckDB.
- Plots percentage and distinguishes battery, charging, and plugged-in states.
- Offers 1H, 24H, 7D, 30D, All, and custom date ranges with hover details.
- Shows recent drain/charging rates in percentage points per hour and macOS time estimates.
- Leaves gaps across sleep, app restarts, and missed sampling intervals.
- Closing history keeps recording; Quit stops it.
- Summoning history moves its window to the active Space; it is not shown on all Spaces.

History is retained indefinitely at:

```text
~/Library/Application Support/Battery History/history.duckdb
```

Timestamps are stored as UTC microseconds, displayed in local time. DuckDB uses
column compression at checkpoint; an active write-ahead log is normal. Rates
need at least ten minutes in an uninterrupted power state. macOS estimates are
shown only when available. Existing macOS battery history cannot be imported.

## Tests

```sh
swift test -j 4
```

Tests cover battery parsing, missing estimates, charging and drain rates,
session/gap handling, transaction rollback, persistence, time-range selection,
chart reduction, recovery after abrupt process exit, and a full year of one-minute
samples with compression inspection. `HistoryStorageProbe` is a test helper,
not part of the shipped app.

Manual hardware checks: unplug/replug power; sleep/wake; close and reopen the
history window; quit and relaunch; enable/disable login and check System Settings.
For Spaces: open history on one desktop, switch desktops, and summon it again.
Repeat with the window closed and minimized. It should appear on the current
desktop without switching desktops, and should not remain visible on the old one.
