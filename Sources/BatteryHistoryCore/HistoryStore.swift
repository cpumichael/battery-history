import Foundation
import class DuckDB.Database
import class DuckDB.Connection
import class DuckDB.PreparedStatement
import class DuckDB.Appender
import struct DuckDB.ResultSet

public struct HistoryPlot: Sendable {
    public let segments: [[BatteryReading]]
    public let sampleCount: Int
    public init(segments: [[BatteryReading]], sampleCount: Int) {
        self.segments = segments
        self.sampleCount = sampleCount
    }
}

public actor HistoryStore {
    private let database: Database
    private let connection: Connection
    public let url: URL

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Battery History", isDirectory: true)
            .appendingPathComponent("history.duckdb")
    }

    public init(url: URL = HistoryStore.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try Database(store: .file(at: url))
        connection = try database.connect()
        try connection.execute("SET threads = 2; SET memory_limit = '128MB';")
        try connection.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        let versions = try connection.query("SELECT version FROM schema_version")
        if versions.rowCount > 0, versions[0].cast(to: Int.self)[0] != 1 {
            throw StoreError.unsupportedSchema
        }
        try connection.execute("BEGIN TRANSACTION")
        do {
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS readings (
                    id VARCHAR PRIMARY KEY,
                    timestamp_us BIGINT NOT NULL,
                    percent DOUBLE NOT NULL CHECK (percent >= 0 AND percent <= 100),
                    state VARCHAR NOT NULL CHECK (state IN ('battery', 'charging', 'pluggedIn')),
                    session VARCHAR NOT NULL,
                    time_to_empty INTEGER,
                    time_to_full INTEGER
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    id VARCHAR PRIMARY KEY, started_us BIGINT NOT NULL,
                    ended_us BIGINT, end_reason VARCHAR
                );
                INSERT INTO schema_version SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
                COMMIT;
                """)
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    public func append(_ reading: BatteryReading) throws {
        try append([reading])
    }

    /// Insert a batch atomically, including its sessions.
    public func append(_ readings: [BatteryReading]) throws {
        guard !readings.isEmpty else { return }
        try connection.execute("BEGIN TRANSACTION")
        do {
            try insertRows(readings)
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    /// Fill empty UTC minutes with the latest system sample known by that minute.
    /// Real samples and app readings are kept; held values extend to startup's cutoff.
    public func backfill(_ candidates: [BatteryReading], before cutoff: Date) throws -> Int {
        let end = floor(cutoff.timeIntervalSince1970 / 60) * 60
        let endMinute = Int64(end / 60)
        var latest: [Int64: BatteryReading] = [:]
        for reading in candidates {
            let time = reading.timestamp.timeIntervalSince1970
            guard time.isFinite, time >= 0, time < end, time < 253_402_300_800,
                  reading.percent.isFinite, (0...100).contains(reading.percent) else { continue }
            let timestampUS = Self.micros(reading.timestamp)
            guard Double(timestampUS) < end * 1_000_000 else { continue }
            let minute = timestampUS / 60_000_000
            if latest[minute].map({ $0.timestamp > reading.timestamp }) == true { continue }
            latest[minute] = reading
        }
        guard let firstMinute = latest.keys.min(), firstMinute < endMinute else { return 0 }
        let lastMinute = endMinute - 1
        try connection.execute("BEGIN TRANSACTION")
        do {
            let query = try PreparedStatement(connection: connection, query: """
                SELECT DISTINCT floor(timestamp_us / 60000000.0)::BIGINT FROM readings
                WHERE timestamp_us >= ? AND timestamp_us < ?
                """)
            try query.bind(firstMinute * 60_000_000, at: 1)
            try query.bind(endMinute * 60_000_000, at: 2)
            let result = try query.execute()
            let occupied = Set(result[0].cast(to: Int64.self).compactMap { $0 })
            var imported: [BatteryReading] = []
            var session = UUID()
            var previous: BatteryReading?
            var lastKnown: BatteryReading?
            for minute in firstMinute...lastMinute {
                if let sample = latest[minute] { lastKnown = sample }
                guard let sample = lastKnown else { continue }
                if occupied.contains(minute) {
                    // Preserve the app's original reading, but use the real Powerlog
                    // observation as the starting value for subsequent carried minutes.
                    previous = nil
                    continue
                }
                let timestamp = latest[minute]?.timestamp ?? Date(timeIntervalSince1970: Double(minute) * 60)
                if let previous {
                    if previous.state != sample.state ||
                        timestamp.timeIntervalSince(previous.timestamp) > HistoryAnalysis.maximumGap {
                        session = UUID()
                    }
                } else {
                    session = UUID()
                }
                let reading = BatteryReading(timestamp: timestamp, percent: sample.percent,
                    state: sample.state, session: session)
                imported.append(reading)
                previous = reading
            }
            try insertRows(imported)
            for group in Dictionary(grouping: imported, by: \.session).values {
                if let last = group.last {
                    try endSession(last.session, at: last.timestamp, reason: "powerlog import")
                }
            }
            try connection.execute("COMMIT")
            return imported.count
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    /// Caller owns the transaction so imports can compare and insert without interleaving.
    private func insertRows(_ readings: [BatteryReading]) throws {
        guard !readings.isEmpty else { return }
        let sessionInsert = try PreparedStatement(connection: connection,
            query: "INSERT INTO sessions (id, started_us) VALUES (?, ?) ON CONFLICT DO NOTHING")
        for reading in Dictionary(grouping: readings, by: \.session).values.compactMap({ $0.first }) {
            try sessionInsert.bind(reading.session.uuidString, at: 1)
            try sessionInsert.bind(Self.micros(reading.timestamp), at: 2)
            _ = try sessionInsert.execute()
        }
        let appender = try Appender(connection: connection, table: "readings")
        for reading in readings {
            try appender.append(reading.id.uuidString)
            try appender.append(Self.micros(reading.timestamp))
            try appender.append(reading.percent)
            try appender.append(reading.state.rawValue)
            try appender.append(reading.session.uuidString)
            try appender.append(reading.timeToEmpty.map(Int32.init))
            try appender.append(reading.timeToFull.map(Int32.init))
            try appender.endRow()
        }
        try appender.flush()
    }

    public func endSession(_ session: UUID, at date: Date, reason: String) throws {
        let statement = try PreparedStatement(connection: connection,
            query: "UPDATE sessions SET ended_us = ?, end_reason = ? WHERE id = ?")
        try statement.bind(Self.micros(date), at: 1)
        try statement.bind(reason, at: 2)
        try statement.bind(session.uuidString, at: 3)
        _ = try statement.execute()
    }

    public func readings(from start: Date, to end: Date) throws -> [BatteryReading] {
        let statement = try PreparedStatement(connection: connection,
            query: "SELECT * FROM readings WHERE timestamp_us >= ? AND timestamp_us <= ? ORDER BY timestamp_us, id")
        try statement.bind(Self.micros(start), at: 1)
        try statement.bind(Self.micros(end), at: 2)
        return try Self.decode(statement.execute())
    }

    public func chart(from start: Date, to end: Date, buckets: Int = 600) throws -> HistoryPlot {
        let low = Self.micros(start), high = Self.micros(end)
        let width = max(1, (high - low) / Int64(max(1, buckets)))
        // Find segments before reducing points. Imported samples can connect a
        // session boundary when actual readings cover it, but rates still use
        // the original sessions. Never connect state changes or long gaps.
        let statement = try PreparedStatement(connection: connection, query: """
            WITH previous AS (
                SELECT r.id, r.timestamp_us, r.percent, r.state, r.session,
                    coalesce(s.end_reason = 'powerlog import', false) AS imported,
                    lag(r.timestamp_us) OVER w AS prev_time,
                    lag(r.state) OVER w AS prev_state, lag(r.session) OVER w AS prev_session,
                    lag(coalesce(s.end_reason = 'powerlog import', false)) OVER w AS prev_imported
                FROM readings r LEFT JOIN sessions s ON s.id = r.session
                WHERE r.timestamp_us >= ? AND r.timestamp_us <= ?
                WINDOW w AS (ORDER BY r.timestamp_us, r.id)
            ), segmented AS (
                SELECT *, sum(CASE WHEN prev_time IS NULL
                    OR (prev_session <> session AND NOT imported AND NOT coalesce(prev_imported, false))
                    OR prev_state <> state OR timestamp_us - prev_time > 180000000
                    OR timestamp_us <= prev_time THEN 1 ELSE 0 END)
                    OVER (ORDER BY timestamp_us, id ROWS UNBOUNDED PRECEDING) AS segment_id,
                    floor((timestamp_us - ?) / ?)::BIGINT AS bucket
                FROM previous
            ), grouped AS MATERIALIZED (
                SELECT segment_id, bucket, arg_min(id, timestamp_us) AS first_id,
                    arg_max(id, timestamp_us) AS last_id, arg_min(id, percent) AS minimum_id,
                    arg_max(id, percent) AS maximum_id, count(*) AS n
                FROM segmented GROUP BY segment_id, bucket
            ), selected AS (
                SELECT DISTINCT unnest([first_id, last_id, minimum_id, maximum_id]) AS id, segment_id
                FROM grouped
            ), counts AS (
                SELECT sum(n)::BIGINT AS total FROM grouped
            )
            SELECT r.id, r.timestamp_us, r.percent, r.state, r.session, r.time_to_empty, r.time_to_full,
                s.segment_id::BIGINT, c.total
            FROM selected s JOIN readings r ON r.id = s.id CROSS JOIN counts c
            ORDER BY r.timestamp_us, r.id
            """)
        try statement.bind(low, at: 1)
        try statement.bind(high, at: 2)
        try statement.bind(low, at: 3)
        try statement.bind(width, at: 4)
        let result = try statement.execute()
        let decoded = Self.decode(result)
        let ids = result[7].cast(to: Int64.self)
        var segments: [[BatteryReading]] = []
        var lastID: Int64?
        for (index, reading) in decoded.enumerated() {
            let segmentID = ids[UInt64(index)]
            if segmentID == lastID, !segments.isEmpty {
                segments[segments.count - 1].append(reading)
            } else {
                segments.append([reading])
            }
            lastID = segmentID
        }
        let count = result.rowCount > 0 ? Int(result[8].cast(to: Int64.self)[0] ?? 0) : 0
        return HistoryPlot(segments: segments, sampleCount: count)
    }

    public func firstDate() throws -> Date? {
        let result = try connection.query("SELECT min(timestamp_us) FROM readings")
        return result[0].cast(to: Int64.self)[0].map(Self.date)
    }

    public func checkpoint() throws { try connection.execute("CHECKPOINT") }

    public func compressionTypes() throws -> [String] {
        let result = try connection.query("SELECT DISTINCT compression FROM pragma_storage_info('readings')")
        return result[0].cast(to: String.self).compactMap { $0 }
    }

    private static func micros(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) }
    private static func date(_ micros: Int64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }

    private static func decode(_ result: ResultSet) -> [BatteryReading] {
        let ids = result[0].cast(to: String.self), times = result[1].cast(to: Int64.self)
        let percents = result[2].cast(to: Double.self), states = result[3].cast(to: String.self)
        let sessions = result[4].cast(to: String.self)
        let empty = result[5].cast(to: Int32.self), full = result[6].cast(to: Int32.self)
        return (0..<result.rowCount).compactMap { i in
            guard let id = ids[i].flatMap(UUID.init(uuidString:)), let time = times[i],
                  let percent = percents[i], let state = states[i].flatMap(PowerState.init(rawValue:)),
                  let session = sessions[i].flatMap(UUID.init(uuidString:)) else { return nil }
            return BatteryReading(id: id, timestamp: date(time), percent: percent, state: state,
                session: session, timeToEmpty: empty[i].map(Int.init), timeToFull: full[i].map(Int.init))
        }
    }

    public enum StoreError: LocalizedError {
        case unsupportedSchema
        public var errorDescription: String? { "This history was created by a newer version of Battery History." }
    }
}
