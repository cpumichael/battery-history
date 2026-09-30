# Battery History implementation plan

Build a native macOS 14+ SwiftUI menu bar app using IOKit battery readings and
Swift Charts. Start quietly at login via SMAppService, with a settings toggle.

Record UTC date, battery percentage, power state, and optional macOS time estimates
every minute while awake, on power changes, and after wake. Distinguish battery,
charging, and plugged in without charging. Mark collection sessions and leave
gaps across sleep, app restarts, and intervals longer than three minutes.

Retain every sample indefinitely in embedded DuckDB, including unchanged readings.
Use transactions, schema versioning, background writes, and hourly checkpoints.
Use database-managed compression rather than change-only SQLite records.

Provide an interactive history window with a fixed 0–100% axis, state colors,
hover details, and 1H/24H/7D/30D/All/custom ranges. Reduce chart points for large
ranges while preserving extrema, transitions, and gaps. Show recent measured
drain/charging rates after ten minutes of uninterrupted readings, and macOS time
estimates only when valid. Closing the window leaves recording running.

Validate parsing, rates, gaps, persistence, unchanged samples, transaction failures,
chart reduction, crash recovery, and a year of compressed synthetic history.
Manually check hardware power transitions, sleep/wake, relaunch, and login status.

Defaults: local storage, UTC timestamps with local display, no import of previous
macOS history. CSV export, sync, notifications, and distribution signing are outside v1.
