import Foundation
import Darwin
import BatteryHistoryCore

/// Development helper: abrupt exit deliberately bypasses deinit and checkpoint.
@main
struct HistoryStorageProbe {
    static func main() async throws {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "battery" {
            if let reading = BatterySource.read(session: UUID()) {
                print("\(reading.percent)% \(reading.state.label), estimate: \(reading.estimatedMinutes.map(String.init) ?? "unavailable")")
            } else {
                print("No internal battery")
            }
            return
        }
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "crash-write" else {
            print("Usage: HistoryStorageProbe battery | crash-write /path/to/test.duckdb")
            exit(2)
        }
        let store = try HistoryStore(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        try await store.append(BatteryReading(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            percent: 42, state: .battery, session: UUID(), timeToEmpty: 90))
        _exit(0)
    }
}
