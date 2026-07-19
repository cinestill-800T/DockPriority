import Foundation
import Testing
@testable import DockPriority

struct WatchdogSchedulerTests {
    @Test func productionIntervalConversionIsExact() {
        #expect(TimerWatchdogScheduler.nanoseconds(for: .seconds(5)) == 5_000_000_000)
    }

    @Test func productionToleranceIsHalfASecond() {
        #expect(TimerWatchdogScheduler.toleranceMilliseconds == 500)
    }
}
