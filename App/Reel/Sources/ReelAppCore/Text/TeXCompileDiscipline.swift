import Foundation
import IOKit.ps

public enum TeXCompileDiscipline {
    public static func allowsAutomaticCompile(
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Double?
    ) -> Bool {
        guard thermalState == .nominal || thermalState == .fair else { return false }
        guard isOnBattery, let batteryLevel else { return true }
        return batteryLevel >= 0.2
    }

    static var allowsAutomaticCompileNow: Bool {
        let battery = batterySnapshot()
        return allowsAutomaticCompile(
            thermalState: ProcessInfo.processInfo.thermalState,
            isOnBattery: battery?.isOnBattery ?? false,
            batteryLevel: battery?.level
        )
    }

    private static func batterySnapshot() -> (isOnBattery: Bool, level: Double?)? {
        guard let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(information)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(information, source)?
                    .takeUnretainedValue() as? [String: Any]
            else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let isOnBattery = state == kIOPSBatteryPowerValue
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let level = current.flatMap { current in
                maximum.flatMap { maximum in maximum > 0 ? current / maximum : nil }
            }
            return (isOnBattery, level)
        }
        return nil
    }
}
