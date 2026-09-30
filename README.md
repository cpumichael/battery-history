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
- Shows the current state, drain rate in `%/hr`, and remaining battery time in the menu bar popover. The drain rate says “Measuring…” until ten minutes of uninterrupted readings are available.
- Shows recent drain/charging rates in `%/hr` and macOS time estimates in history.
- On startup and after waking, fills each missing minute with the latest available Powerlog battery level and state, preserving actual app and system readings.
- Carries the latest Powerlog reading forward through the last complete minute before each check when system samples are sparse.
- Closing history keeps recording; Quit stops it.
- Summoning history moves its window to the active Space; it is not shown on all Spaces.

History is retained indefinitely at:

```text
~/Library/Application Support/Battery History/history.duckdb
```

Timestamps are stored as UTC microseconds, displayed in local time. DuckDB uses
column compression at checkpoint; an active write-ahead log is normal. Rates
need at least ten minutes in an uninterrupted power state. macOS estimates are
shown only when available. At startup and after each wake, the app reads available history from
`/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL` in the background.
It imports valid readings for empty UTC minutes before the check's current minute,
retaining original timestamps for real samples and carrying the latest known value
forward for missing minutes. This fills sleep gaps when Powerlog retained samples
for that interval; carried values are estimates, not new battery measurements.
Existing readings are never replaced, and repeated checks do not duplicate imports.
Imported sessions stay separate for
rate calculations, while the graph connects through imported readings when the
power state is unchanged and adjacent samples are at most three minutes apart.
Historical time estimates are unavailable. Only the current system
log is checked, and its retention varies. Failure to read Powerlog is nonfatal:
if the database is missing, unreadable, locked, or incompatible, Settings reports
that status and normal battery recording continues. The app retries backfill at
the next wake or startup. Preview mode skips system history.

## Tests

```sh
swift test -j 4
```

Tests cover battery parsing, missing estimates, charging and drain rates,
session/gap handling, transaction rollback, persistence, time-range selection,
chart reduction, recovery after abrupt process exit, and a full year of one-minute
samples with compression inspection. Powerlog fixtures cover validation, missing or
locked databases, minute selection, preservation of existing readings, repeat imports,
session boundaries, cancellation, and rollback. To also check this Mac’s real
Powerlog against a temporary history database, run
`BATTERY_HISTORY_CHECK_POWERLOG=1 swift test -j 4 --filter PowerlogTests`.
`HistoryStorageProbe` is a test helper,
not part of the shipped app.

Manual hardware checks: unplug/replug power; sleep/wake; close and reopen the
history window; quit and relaunch; enable/disable login and check System Settings.
For Spaces: open history on one desktop, switch desktops, and summon it again.
Repeat with the window closed and minimized. It should appear on the current
desktop without switching desktops, and should not remain visible on the old one.
