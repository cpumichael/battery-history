import XCTest
import IOKit.ps
@testable import BatteryHistoryCore

final class HistoryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = UUID()

    private func reading(_ minute: Int, _ percent: Double, state: PowerState = .battery,
                         session: UUID? = nil) -> BatteryReading {
        BatteryReading(timestamp: origin.addingTimeInterval(Double(minute) * 60), percent: percent,
                       state: state, session: session ?? self.session)
    }

    func testEmptyRate() {
        XCTAssertNil(HistoryAnalysis.rate([]))
    }

    func testDrainAndChargingRates() {
        let drain = (0...30).map { reading($0, 80 - Double($0) / 5) }
        XCTAssertEqual(HistoryAnalysis.rate(drain)!, -12, accuracy: 0.001)
        let charge = (0...30).map { reading($0, 40 + Double($0) / 2, state: .charging) }
        XCTAssertEqual(HistoryAnalysis.rate(charge)!, 30, accuracy: 0.001)
    }

    func testInsufficientFlatAndConflictingTrends() {
        XCTAssertNil(HistoryAnalysis.rate((0...9).map { reading($0, 80 - Double($0)) }))
        XCTAssertNil(HistoryAnalysis.rate((0...20).map { reading($0, 80) }))
        XCTAssertNil(HistoryAnalysis.rate((0...20).map { reading($0, 40 + Double($0)) }))
        XCTAssertNil(HistoryAnalysis.rate((0...20).map { reading($0, 80 - Double($0), state: .pluggedIn) }))
    }

    func testGapSessionAndPowerTransitionResetRate() {
        let drain = (0...20).map { reading($0, 80 - Double($0) / 5) }
        XCTAssertNil(HistoryAnalysis.rate(drain + [reading(30, 60)]))
        XCTAssertNil(HistoryAnalysis.rate(drain + [reading(21, 60, session: UUID())]))
        XCTAssertNil(HistoryAnalysis.rate(drain + [reading(21, 60, state: .charging)]))
        XCTAssertNil(HistoryAnalysis.rate(drain + [reading(20, 60)]))
    }

    func testReductionPreservesExtremaTransitionsAndGaps() {
        var readings = (0...100).map { reading($0, $0 == 50 ? 1 : 80) }
        readings += [reading(101, 81, state: .charging), reading(120, 82, state: .charging),
                     reading(121, 82, state: .charging, session: UUID())]
        let reduced = HistoryAnalysis.reduced(readings, buckets: 2)
        XCTAssertEqual(reduced.count, 4)
        XCTAssertTrue(reduced[0].contains { $0.percent == 1 })
        XCTAssertEqual(reduced[0].first?.timestamp, readings.first?.timestamp)
        XCTAssertEqual(reduced[0].last?.timestamp, readings[100].timestamp)
    }

    func testBatteryParsingAndEstimates() {
        var values: [String: Any] = [kIOPSCurrentCapacityKey: 45, kIOPSMaxCapacityKey: 90,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsChargingKey: false,
            kIOPSTimeToEmptyKey: 120, kIOPSTimeToFullChargeKey: 40]
        let battery = BatterySource.parse(values, session: session, now: origin)
        XCTAssertEqual(battery?.percent, 50)
        XCTAssertEqual(battery?.state, .battery)
        XCTAssertEqual(battery?.estimatedMinutes, 120)
        XCTAssertNil(battery?.timeToFull)
        values[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        XCTAssertEqual(BatterySource.parse(values, session: session, now: origin)?.state, .pluggedIn)
        values[kIOPSIsChargingKey] = true
        XCTAssertEqual(BatterySource.parse(values, session: session, now: origin)?.estimatedMinutes, 40)
        values[kIOPSTimeToFullChargeKey] = -1
        XCTAssertNil(BatterySource.parse(values, session: session, now: origin)?.estimatedMinutes)
        values[kIOPSMaxCapacityKey] = 0
        XCTAssertNil(BatterySource.parse(values, session: session, now: origin))
        values[kIOPSMaxCapacityKey] = 90
        values[kIOPSCurrentCapacityKey] = 200
        XCTAssertNil(BatterySource.parse(values, session: session, now: origin))
    }
}
