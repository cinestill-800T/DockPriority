import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import DockPriority

struct SystemDisplayInventoryTests {
    @Test func mapsEveryFlagInACombinedReconfigurationCallback() {
        let flags: CGDisplayChangeSummaryFlags = [
            .beginConfigurationFlag,
            .addFlag,
            .removeFlag,
            .enabledFlag,
            .disabledFlag,
            .movedFlag,
            .setModeFlag,
            .desktopShapeChangedFlag,
            .setMainFlag,
            .mirrorFlag,
            .unMirrorFlag,
        ]

        let reasons = DisplayChangeReason.reasons(for: flags)

        #expect(reasons.contains(.reconfigurationBegan))
        #expect(reasons.contains(.displayAdded))
        #expect(reasons.contains(.displayRemoved))
        #expect(reasons.contains(.displayEnabled))
        #expect(reasons.contains(.displayDisabled))
        #expect(reasons.contains(.displayMoved))
        #expect(reasons.contains(.displayModeChanged))
        #expect(reasons.contains(.desktopShapeChanged))
        #expect(reasons.contains(.mainDisplayChanged))
        #expect(reasons.filter { $0 == .mirroringChanged }.count == 1)
    }

    @Test func zeroFlagsDoNotInventAReason() {
        #expect(DisplayChangeReason.reasons(for: []).isEmpty)
    }

    @Test func onlySettledWakeAndSessionActiveReasonsRefreshInventory() {
        let refreshReasons = DisplayChangeReason.allCases.filter(\.triggersInventoryRefresh)

        #expect(refreshReasons == [.configurationSettled, .systemWake, .screenUnlocked])
    }

    @Test func configurationBurstEmitsRawReasonsThenOneSettledReason() async throws {
        let recorder = ReasonRecorder()
        let inventory = SystemDisplayInventory(
            deliveryQueue: DispatchQueue(label: "inventory-debounce-test"),
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter(),
            settleDelay: 0.02,
            observesCGDisplayChanges: false
        )
        inventory.startObserving { recorder.append($0) }
        defer { inventory.stopObserving() }

        inventory.receiveReconfiguration(flags: [.beginConfigurationFlag, .setModeFlag])
        inventory.receiveReconfiguration(flags: [.movedFlag, .setMainFlag])
        try await Task.sleep(for: .milliseconds(100))

        let reasons = recorder.values
        #expect(reasons.contains(.reconfigurationBegan))
        #expect(reasons.contains(.displayModeChanged))
        #expect(reasons.contains(.displayMoved))
        #expect(reasons.contains(.mainDisplayChanged))
        #expect(reasons.filter { $0 == .configurationSettled }.count == 1)
        #expect(reasons.last == .configurationSettled)
    }

    @Test func documentedWorkspaceSessionActiveNotificationMapsToUnlockReason() async throws {
        let recorder = ReasonRecorder()
        let workspaceCenter = NotificationCenter()
        let inventory = SystemDisplayInventory(
            deliveryQueue: DispatchQueue(label: "inventory-session-test"),
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: workspaceCenter,
            settleDelay: 0.02,
            wakeDelay: 0.02,
            observesCGDisplayChanges: false
        )
        inventory.startObserving { recorder.append($0) }
        defer { inventory.stopObserving() }

        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await waitUntil { recorder.values == [.screenUnlocked] }

        #expect(recorder.values == [.screenUnlocked])
    }

    @Test func documentedScreenWakeNotificationMapsToUnlockReasonAfterStabilization() async throws {
        let recorder = ReasonRecorder()
        let workspaceCenter = NotificationCenter()
        let inventory = SystemDisplayInventory(
            deliveryQueue: DispatchQueue(label: "inventory-screen-wake-test"),
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: workspaceCenter,
            settleDelay: 0.02,
            wakeDelay: 0.25,
            observesCGDisplayChanges: false
        )
        inventory.startObserving { recorder.append($0) }
        defer { inventory.stopObserving() }

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.values.isEmpty)

        try await waitUntil { recorder.values == [.screenUnlocked] }
        #expect(recorder.values == [.screenUnlocked])
    }

    @Test func systemScreenAndSessionWakeBurstCoalescesToOneRefreshReason() async throws {
        let recorder = ReasonRecorder()
        let workspaceCenter = NotificationCenter()
        let inventory = SystemDisplayInventory(
            deliveryQueue: DispatchQueue(label: "inventory-wake-coalescing-test"),
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: workspaceCenter,
            settleDelay: 0.02,
            wakeDelay: 0.02,
            observesCGDisplayChanges: false
        )
        inventory.startObserving { recorder.append($0) }
        defer { inventory.stopObserving() }

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await waitUntil { recorder.values == [.systemWake] }

        #expect(recorder.values == [.systemWake])
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    interval: Duration = .milliseconds(10),
    condition: @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while true {
        try Task.checkCancellation()
        guard !condition() else { return }
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return }
        try await Task.sleep(for: min(interval, remaining))
    }
}

private final class ReasonRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [DisplayChangeReason] = []

    var values: [DisplayChangeReason] {
        lock.lock()
        defer { lock.unlock() }
        return reasons
    }

    func append(_ reason: DisplayChangeReason) {
        lock.lock()
        reasons.append(reason)
        lock.unlock()
    }
}
