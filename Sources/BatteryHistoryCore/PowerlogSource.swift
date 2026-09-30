import Foundation
import SQLite3

/// Reads the system's retained battery samples without changing its database.
public enum PowerlogSource {
    public static let defaultURL = URL(fileURLWithPath:
        "/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL")

    public static func read(url: URL = defaultURL, before cutoff: Date) throws -> [BatteryReading] {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(database) }
        func failure() -> ReadError {
            ReadError(message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database")
        }
        guard result == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(database, 1000)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        var statement: OpaquePointer?
        let sql = """
            SELECT timestamp, Level, IsCharging, ExternalConnected
            FROM PLBatteryAgent_EventBackward_Battery
            WHERE timestamp < ? ORDER BY timestamp, ID
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let end = floor(cutoff.timeIntervalSince1970 / 60) * 60
        sqlite3_bind_double(statement, 1, end)
        let session = UUID()
        var readings: [BatteryReading] = []
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            guard (0...3).allSatisfy({
                let type = sqlite3_column_type(statement, Int32($0))
                return type == SQLITE_INTEGER || type == SQLITE_FLOAT
            }) else { continue }
            let timestamp = sqlite3_column_double(statement, 0)
            let percent = sqlite3_column_double(statement, 1)
            let charging = sqlite3_column_double(statement, 2)
            let external = sqlite3_column_double(statement, 3)
            guard timestamp.isFinite, timestamp >= 0, timestamp < end,
                  timestamp < 253_402_300_800, percent.isFinite, (0...100).contains(percent),
                  (charging == 0 || charging == 1), (external == 0 || external == 1) else { continue }
            let state: PowerState = external == 0 ? .battery : (charging == 1 ? .charging : .pluggedIn)
            readings.append(BatteryReading(timestamp: Date(timeIntervalSince1970: timestamp),
                percent: percent, state: state, session: session))
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure() }
        return readings
    }

    public struct ReadError: LocalizedError {
        public let message: String
        public var errorDescription: String? { "System history unavailable: \(message)" }
    }
}
