//
//  WatchdogScheduler.swift
//  DockPriority
//

import Foundation

protocol WatchdogScheduling: AnyObject {
    func start(interval: Duration, tick: @escaping @Sendable () -> Void)
    func stop()
}

/// A monotonic, low-overhead watchdog. The production coordinator always uses
/// a five-second interval; the half-second leeway lets macOS coalesce wakeups.
final class TimerWatchdogScheduler: WatchdogScheduling, @unchecked Sendable {
    static let toleranceMilliseconds = 500

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "io.github.cinestill800t.DockPriority.watchdog",
            qos: .utility
        )
    ) {
        self.queue = queue
    }

    deinit {
        stop()
    }

    func start(interval: Duration, tick: @escaping @Sendable () -> Void) {
        stop()

        let nanoseconds = Self.nanoseconds(for: interval)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler(handler: tick)
        source.schedule(
            deadline: .now() + .nanoseconds(nanoseconds),
            repeating: .nanoseconds(nanoseconds),
            leeway: .milliseconds(Self.toleranceMilliseconds)
        )

        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()

        source?.setEventHandler {}
        source?.cancel()
    }

    static func nanoseconds(for duration: Duration) -> Int {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let secondsAsNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if secondsAsNanoseconds.overflow { return Int.max }
        let subsecondNanoseconds = attoseconds / 1_000_000_000
        let total = secondsAsNanoseconds.partialValue.addingReportingOverflow(subsecondNanoseconds)
        if total.overflow { return Int.max }
        return max(Int(total.partialValue), 1)
    }
}
