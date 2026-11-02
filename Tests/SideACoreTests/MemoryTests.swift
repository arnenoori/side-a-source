import Foundation
import Testing
@testable import SideACore

@Test func memoryIsTightOnlyUnderKernelPressureWithLargeSessions() {
    #expect(MemoryPressure(sessionsMB: 11_264, level: 2).tight)
    #expect(MemoryPressure(sessionsMB: 4_096, level: 4).tight)
    #expect(!MemoryPressure(sessionsMB: 3_000, level: 4).tight)
    #expect(!MemoryPressure(sessionsMB: 11_264, level: 1).tight)
    #expect(!MemoryPressure(sessionsMB: 11_264, level: 0).tight)
    #expect(MemoryPressure.currentLevel().map { [0, 1, 2, 4].contains($0) } ?? true)
}

@Test func memoryAmountsShowOneDecimalUnderTenGigabytes() {
    #expect(MemoryPressure.gigabytes(5_018) == "4.9 GB")
    #expect(MemoryPressure.gigabytes(4_096) == "4.0 GB")
    #expect(MemoryPressure.gigabytes(10_189) == "10 GB")
    #expect(MemoryPressure.gigabytes(11_264) == "11 GB")
    let pressure = MemoryPressure(sessionsMB: 5_018, level: 2)
    #expect(pressure.line == "Sessions hold 4.9 GB · memory is tight")
    #expect(pressure.notification.contains("hold 4.9 GB"))
    #expect(MemoryPressure(sessionsMB: 5_018, level: 4).notification.contains("critical"))
}

@Test func memoryNotificationsComeAtMostHourly() {
    let now = Date()
    #expect(MemoryPressure.shouldNotify(now: now, last: nil))
    #expect(!MemoryPressure.shouldNotify(now: now, last: now.addingTimeInterval(-1800)))
    #expect(MemoryPressure.shouldNotify(now: now, last: now.addingTimeInterval(-3600)))
}
