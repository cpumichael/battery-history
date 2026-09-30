import XCTest
import class DuckDB.Database
@testable import BatteryHistoryCore

final class StoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("history.duckdb") }
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryHistoryTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testPersistenceIdenticalSamplesAndRangeQueries() async throws {
        let session = UUID()
        let readings = (0..<20).map {
            BatteryReading(timestamp: origin.addingTimeInterval(Double($0) * 60), percent: 80,
                           state: .pluggedIn, session: session)
        }
        try await writeAndClose(readings)
        let reopened = try HistoryStore(url: url)
        let all = try await reopened.readings(from: origin, to: origin.addingTimeInterval(2000))
        XCTAssertEqual(all, readings)
        let range = try await reopened.readings(from: origin.addingTimeInterval(300), to: origin.addingTimeInterval(600))
        XCTAssertEqual(range, Array(readings[5...10]))
        let first = try await reopened.firstDate()
        XCTAssertEqual(first, origin)
    }

    private func writeAndClose(_ readings: [BatteryReading]) async throws {
        let store = try HistoryStore(url: url)
        try await store.append(readings)
        try await store.endSession(readings[0].session, at: readings.last!.timestamp, reason: "quit")
        try await store.checkpoint()
    }

    func testEmptyStore() async throws {
        let store = try HistoryStore(url: url)
        let first = try await store.firstDate()
        XCTAssertNil(first)
        let chart = try await store.chart(from: origin, to: origin.addingTimeInterval(1000))
        XCTAssertEqual(chart.sampleCount, 0)
        XCTAssertTrue(chart.segments.isEmpty)
    }

    func testNewerSchemaIsRejectedWithoutChangingIt() throws {
        try createFutureSchema()
        XCTAssertThrowsError(try HistoryStore(url: url))
        let database = try Database(store: .file(at: url))
        let connection = try database.connect()
        let version = try connection.query("SELECT version FROM schema_version")[0].cast(to: Int.self)[0]
        XCTAssertEqual(version, 2)
    }

    private func createFutureSchema() throws {
        let database = try Database(store: .file(at: url))
        let connection = try database.connect()
        try connection.execute("CREATE TABLE schema_version (version INTEGER NOT NULL); INSERT INTO schema_version VALUES (2)")
    }

    func testCommittedReadingSurvivesAbruptProcessExit() async throws {
        // SwiftPM puts executable products beside the test bundle.
        let products = Bundle(for: StoreTests.self).bundleURL.deletingLastPathComponent()
        let process = Process()
        process.executableURL = products.appendingPathComponent("HistoryStorageProbe")
        process.arguments = ["crash-write", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let store = try HistoryStore(url: url)
        let readings = try await store.readings(from: origin, to: origin.addingTimeInterval(60))
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.percent, 42)
        XCTAssertEqual(readings.first?.timeToEmpty, 90)
    }

    func testFailedBatchRollsBackCompletely() async throws {
        let store = try HistoryStore(url: url)
        let reading = BatteryReading(timestamp: origin, percent: 80, state: .battery, session: UUID())
        do {
            try await store.append([reading, reading])
            XCTFail("Duplicate IDs must fail")
        } catch {}
        let all = try await store.readings(from: origin, to: origin.addingTimeInterval(60))
        XCTAssertTrue(all.isEmpty)
        try await store.append(reading)
    }

    func testSQLReductionPreservesExtremaAndBoundaries() async throws {
        let store = try HistoryStore(url: url), session = UUID()
        var readings = (0...100).map {
            BatteryReading(timestamp: origin.addingTimeInterval(Double($0) * 60),
                percent: $0 == 50 ? 1 : 80, state: .battery, session: session)
        }
        readings += [BatteryReading(timestamp: origin.addingTimeInterval(6060), percent: 81, state: .charging, session: session),
                     BatteryReading(timestamp: origin.addingTimeInterval(7200), percent: 82, state: .charging, session: session),
                     BatteryReading(timestamp: origin.addingTimeInterval(7260), percent: 82, state: .charging, session: UUID())]
        try await store.append(readings)
        let chart = try await store.chart(from: origin, to: origin.addingTimeInterval(7300), buckets: 2)
        XCTAssertEqual(chart.sampleCount, readings.count)
        XCTAssertEqual(chart.segments.count, 4)
        XCTAssertTrue(chart.segments[0].contains { $0.percent == 1 })
        XCTAssertEqual(chart.segments[0].first?.id, readings.first?.id)
        XCTAssertEqual(chart.segments[0].last?.id, readings[100].id)
    }

    func testYearOfCompressedHistory() async throws {
        let store = try HistoryStore(url: url), session = UUID()
        for day in 0..<365 {
            let readings = (0..<1440).map { minute in
                BatteryReading(timestamp: origin.addingTimeInterval(Double(day * 1440 + minute) * 60),
                    percent: 80, state: .pluggedIn, session: session)
            }
            try await store.append(readings)
        }
        try await store.checkpoint()
        let chart = try await store.chart(from: origin, to: origin.addingTimeInterval(365 * 86400))
        XCTAssertEqual(chart.sampleCount, 525_600)
        XCTAssertEqual(chart.segments.count, 1)
        XCTAssertLessThan(chart.segments[0].count, 2500)
        let compression = try await store.compressionTypes()
        XCTAssertTrue(compression.contains { $0 != "Uncompressed" }, "Expected a compressed column: \(compression)")
        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        print("Year of history: \(bytes.intValue) bytes; codecs: \(compression.joined(separator: ", "))")
    }
}
