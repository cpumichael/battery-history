import XCTest
import SQLite3
@testable import BatteryHistoryCore

final class PowerlogTests: XCTestCase {
    private var directory: URL!
    private var source: URL { directory.appendingPathComponent("powerlog.sqlite") }
    private var history: URL { directory.appendingPathComponent("history.duckdb") }
    // Aligned to a UTC minute.
    private let origin = Date(timeIntervalSince1970: 1_700_000_040)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PowerlogTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            XCTFail(String(cString: sqlite3_errmsg(database)))
            return
        }
    }

    func testReaderValidationStatesCutoffAndReadOnly() throws {
        try fixture("""
            CREATE TABLE PLBatteryAgent_EventBackward_Battery
                (ID INTEGER PRIMARY KEY, timestamp REAL, Level REAL, IsCharging INTEGER, ExternalConnected INTEGER);
            INSERT INTO PLBatteryAgent_EventBackward_Battery VALUES
                (1, 1700000040.5, 80, 0, 0),
                (2, 1700000100, 81, 1, 1),
                (3, 1700000160, 82, 0, 1),
                (4, 1700000161, 83, 1, 0),
                (5, 1700000170, NULL, 0, 0),
                (6, 1700000171, 101, 0, 0),
                (7, 1700000172, 80, 2, 0),
                (8, 1700000173, 80, 0, NULL),
                (9, 1700000174, 'bad', 0, 0),
                (10, -1, 80, 0, 0),
                (11, 1700000220, 80, 0, 0),
                (12, 1700000280, 80, 0, 0);
            """)
        let bytes = try Data(contentsOf: source)
        let samples = try PowerlogSource.read(url: source, before: origin.addingTimeInterval(200))
        XCTAssertEqual(samples.map(\.state), [.battery, .charging, .pluggedIn, .battery])
        XCTAssertEqual(samples.first?.timestamp.timeIntervalSince1970, 1_700_000_040.5)
        XCTAssertTrue(samples.allSatisfy { $0.timeToEmpty == nil && $0.timeToFull == nil })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testMissingAndIncompatibleSourcesFailWithoutCreation() throws {
        XCTAssertThrowsError(try PowerlogSource.read(url: source, before: Date()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try fixture("CREATE TABLE PLBatteryAgent_EventBackward_Battery (ID INTEGER, timestamp REAL)")
        XCTAssertThrowsError(try PowerlogSource.read(url: source, before: Date()))
    }

    func testCorruptAndLockedSourcesFail() throws {
        try Data("not sqlite".utf8).write(to: source)
        XCTAssertThrowsError(try PowerlogSource.read(url: source, before: Date()))
        try FileManager.default.removeItem(at: source)
        try fixture("CREATE TABLE PLBatteryAgent_EventBackward_Battery (ID INTEGER, timestamp REAL, Level REAL, IsCharging INTEGER, ExternalConnected INTEGER)")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        XCTAssertThrowsError(try PowerlogSource.read(url: source, before: Date()))
    }

    private func sample(_ seconds: Double, percent: Double = 80, id: UUID = UUID()) -> BatteryReading {
        BatteryReading(id: id, timestamp: origin.addingTimeInterval(seconds), percent: percent,
            state: .battery, session: UUID(), timeToEmpty: 90)
    }

    func testBackfillPreservesReadingsSelectsLatestAndIsIdempotent() async throws {
        let live = sample(65, percent: 42)
        let candidates = [sample(5), sample(40, percent: 79), sample(70), sample(125), sample(185)]
        let cutoff = origin.addingTimeInterval(200)
        try await importAndClose(live: live, candidates: candidates, cutoff: cutoff)
        let reopened = try HistoryStore(url: history)
        let rows = try await reopened.readings(from: origin, to: cutoff)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].timestamp, origin.addingTimeInterval(40))
        XCTAssertEqual(rows[0].percent, 79)
        XCTAssertEqual(rows[1], live)
        XCTAssertEqual(rows[2].timestamp, origin.addingTimeInterval(125))
        XCTAssertNotEqual(rows[0].session, rows[2].session)
        XCTAssertNotEqual(rows[0].session, live.session)
        XCTAssertNil(rows[0].timeToEmpty)
        let repeated = try await reopened.backfill(candidates, before: cutoff)
        XCTAssertEqual(repeated, 0)
        let after = try await reopened.readings(from: origin, to: cutoff)
        XCTAssertEqual(after, rows)
    }

    private func importAndClose(live: BatteryReading, candidates: [BatteryReading], cutoff: Date) async throws {
        let store = try HistoryStore(url: history)
        try await store.append(live)
        let count = try await store.backfill(candidates, before: cutoff)
        XCTAssertEqual(count, 2)
        try await store.checkpoint()
    }

    func testEmptyStoreGapsAndLiveRateIsolation() async throws {
        let store = try HistoryStore(url: history)
        let candidates = [sample(5), sample(65), sample(245), sample(485), sample(545)]
        let count = try await store.backfill(candidates, before: origin.addingTimeInterval(600))
        XCTAssertEqual(count, 5)
        let live = sample(605, percent: 70)
        try await store.append(live)
        let rows = try await store.readings(from: origin, to: origin.addingTimeInterval(660))
        XCTAssertEqual(rows[0].session, rows[2].session) // Exactly three minutes stays continuous.
        XCTAssertNotEqual(rows[2].session, rows[3].session)
        XCTAssertEqual(rows[3].session, rows[4].session)
        XCTAssertNil(HistoryAnalysis.rate(rows))
        let chart = try await store.chart(from: origin, to: origin.addingTimeInterval(660))
        XCTAssertEqual(chart.segments.count, 2)
        XCTAssertEqual(chart.sampleCount, 6)
    }

    func testOccupiedMinuteWithoutCandidateSplitsSession() async throws {
        let store = try HistoryStore(url: history)
        try await store.append(sample(65))
        let count = try await store.backfill([sample(5), sample(125)], before: origin.addingTimeInterval(180))
        XCTAssertEqual(count, 2)
        let rows = try await store.readings(from: origin, to: origin.addingTimeInterval(180))
        XCTAssertEqual(Set(rows.map(\.session)).count, 3)
    }

    func testBackfillFailureRollsBackAndCanRetry() async throws {
        let store = try HistoryStore(url: history)
        let duplicateID = UUID()
        let candidates = [sample(5, id: duplicateID), sample(65, id: duplicateID)]
        do {
            _ = try await store.backfill(candidates, before: origin.addingTimeInterval(180))
            XCTFail("Duplicate IDs should roll back")
        } catch {}
        let rows = try await store.readings(from: origin, to: origin.addingTimeInterval(180))
        XCTAssertTrue(rows.isEmpty)
        let retry = try await store.backfill([sample(5), sample(65)], before: origin.addingTimeInterval(180))
        XCTAssertEqual(retry, 2)
    }

    func testBackfillConnectsRestartGapInChartButNotRates() async throws {
        let store = try HistoryStore(url: history)
        let before = sample(16), after = sample(266)
        try await store.append([before, after])
        let count = try await store.backfill([sample(115), sample(175), sample(235)],
            before: origin.addingTimeInterval(266))
        XCTAssertEqual(count, 3)
        let chart = try await store.chart(from: origin, to: origin.addingTimeInterval(300))
        XCTAssertEqual(chart.sampleCount, 5)
        XCTAssertEqual(chart.segments.count, 1)
        XCTAssertEqual(chart.segments.first?.first?.id, before.id)
        XCTAssertEqual(chart.segments.first?.last?.id, after.id)
        let readings = try await store.readings(from: origin, to: origin.addingTimeInterval(300))
        XCTAssertEqual(Set(readings.map(\.session)).count, 3)
        XCTAssertNil(HistoryAnalysis.rate(readings))
    }

    func testBackfillChartStillBreaksForMissingDataAndPowerChanges() async throws {
        let store = try HistoryStore(url: history)
        let before = sample(5), after = sample(605)
        try await store.append([before, after])
        let charging = BatteryReading(timestamp: origin.addingTimeInterval(125), percent: 81,
            state: .charging, session: UUID())
        _ = try await store.backfill([sample(65), charging, sample(545)],
            before: origin.addingTimeInterval(660))
        let chart = try await store.chart(from: origin, to: origin.addingTimeInterval(660))
        XCTAssertEqual(chart.segments.count, 3)
        XCTAssertEqual(chart.segments.map { $0.count }, [2, 1, 2])
    }

    func testMinuteBoundaryRoundingIsIdempotent() async throws {
        let store = try HistoryStore(url: history)
        let candidates = [sample(59.9999998), sample(119.9999998)]
        let count = try await store.backfill(candidates, before: origin.addingTimeInterval(120))
        XCTAssertEqual(count, 1) // The second sample rounds into the excluded startup minute.
        let again = try await store.backfill(candidates, before: origin.addingTimeInterval(120))
        XCTAssertEqual(again, 0)
    }

    func testInvalidCandidatesAreSkipped() async throws {
        let store = try HistoryStore(url: history)
        let candidates = [sample(5, percent: .nan), sample(65, percent: -1),
                          sample(125, percent: 101), sample(-1_800_000_000), sample(185)]
        let count = try await store.backfill(candidates, before: origin.addingTimeInterval(240))
        XCTAssertEqual(count, 1)
    }

    func testCancelledReaderStops() async throws {
        try fixture("CREATE TABLE PLBatteryAgent_EventBackward_Battery (ID INTEGER, timestamp REAL, Level REAL, IsCharging INTEGER, ExternalConnected INTEGER)")
        let source = source
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PowerlogSource.read(url: source, before: Date())
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled reader should stop")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRealPowerlogReadOnlyWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["BATTERY_HISTORY_CHECK_POWERLOG"] == "1" else {
            throw XCTSkip("Opt-in check of this Mac's system database")
        }
        let cutoff = Date()
        let samples = try PowerlogSource.read(before: cutoff)
        XCTAssertFalse(samples.isEmpty)
        let store = try HistoryStore(url: history)
        let count = try await store.backfill(samples, before: cutoff)
        XCTAssertGreaterThan(count, 0)
        let repeatCount = try await store.backfill(samples, before: cutoff)
        XCTAssertEqual(repeatCount, 0)
        print("Read \(samples.count) system samples and backfilled \(count) minutes into a temporary database")
    }
}
