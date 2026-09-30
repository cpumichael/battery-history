import Foundation
import IOKit.ps

public enum BatterySource {
    public static func read(session: UUID, now: Date = Date()) -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return parse(description, session: session, now: now)
        }
        return nil
    }

    public static func parse(_ values: [String: Any], session: UUID, now: Date) -> BatteryReading? {
        guard let current = values[kIOPSCurrentCapacityKey] as? NSNumber,
              let maximum = values[kIOPSMaxCapacityKey] as? NSNumber,
              maximum.doubleValue > 0,
              current.doubleValue >= 0, current.doubleValue <= maximum.doubleValue,
              let source = values[kIOPSPowerSourceStateKey] as? String,
              source == kIOPSBatteryPowerValue || source == kIOPSACPowerValue else { return nil }
        let charging = (values[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
        let state: PowerState = source == kIOPSBatteryPowerValue ? .battery : (charging ? .charging : .pluggedIn)
        func estimate(_ key: String) -> Int? {
            guard let number = values[key] as? NSNumber, number.intValue > 0 else { return nil }
            return number.intValue
        }
        return BatteryReading(timestamp: now, percent: current.doubleValue / maximum.doubleValue * 100,
                              state: state, session: session,
                              timeToEmpty: state == .battery ? estimate(kIOPSTimeToEmptyKey) : nil,
                              timeToFull: state == .charging ? estimate(kIOPSTimeToFullChargeKey) : nil)
    }
}
