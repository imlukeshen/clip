import Foundation
import Testing

@testable import ReelAppCore

@Suite("TeX automatic compile discipline")
struct TeXCompileDisciplineTests {
    @Test("Battery below twenty percent pauses automatic work")
    func lowBatteryPauses() {
        #expect(
            !TeXCompileDiscipline.allowsAutomaticCompile(
                thermalState: .nominal,
                isOnBattery: true,
                batteryLevel: 0.19
            )
        )
        #expect(
            TeXCompileDiscipline.allowsAutomaticCompile(
                thermalState: .nominal,
                isOnBattery: true,
                batteryLevel: 0.2
            )
        )
    }

    @Test("Serious thermal pressure pauses regardless of power source")
    func thermalPressurePauses() {
        #expect(
            !TeXCompileDiscipline.allowsAutomaticCompile(
                thermalState: .serious,
                isOnBattery: false,
                batteryLevel: nil
            )
        )
        #expect(
            TeXCompileDiscipline.allowsAutomaticCompile(
                thermalState: .fair,
                isOnBattery: false,
                batteryLevel: nil
            )
        )
    }
}
