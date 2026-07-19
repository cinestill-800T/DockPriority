//
//  DockPriorityCoordinator.swift
//  DockPriority
//

import Foundation
import OSLog
import SwiftUI

enum ProtectionState: Equatable, Sendable {
    case stopped
    case active

    var isActive: Bool { self == .active }
}

enum DockPriorityStatus: Equatable, Sendable {
    case idle
    case protectionStopped
    case protecting
    case targetReady
    case noAvailableDisplays
    case moved(DisplayIdentity)
    case accessibilityPermissionRequired
    case inventoryFailed(String)
    case dockLocationFailed(String)
    case relocationFailed(String)
    case persistenceFailed(String)

    var message: String {
        switch self {
        case .idle:
            return ""
        case .protectionStopped:
            return "Protection is stopped."
        case .protecting:
            return "Protection is active."
        case .targetReady:
            return "The Dock is on the effective target."
        case .noAvailableDisplays:
            return "No available displays."
        case .moved:
            return "The Dock was moved to the effective target."
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required to locate and move the Dock."
        case let .inventoryFailed(message):
            return "Display inventory error: \(message)"
        case let .dockLocationFailed(message):
            return "Dock location error: \(message)"
        case let .relocationFailed(message):
            return "Dock relocation error: \(message)"
        case let .persistenceFailed(message):
            return "Display priority could not be saved: \(message)"
        }
    }
}

enum ReconcileReason: Equatable, Sendable {
    case refresh
    case watchdog
    case displayChange(DisplayChangeReason)
    case protectionStarted
    case protectionStopped
    case priorityChanged
    case temporarySelected
    case returnToPriority

    var clearsTemporaryTarget: Bool {
        if case .displayChange = self { return true }
        return false
    }

    var isManualOneShot: Bool {
        self == .temporarySelected || self == .returnToPriority
    }
}

@MainActor
final class DockPriorityCoordinator: ObservableObject {
    @Published private(set) var rememberedDisplays: [RememberedDisplay]
    @Published private(set) var activeDisplays: [DisplaySnapshot] = []
    @Published private(set) var protectionState: ProtectionState = .stopped
    @Published private(set) var temporaryTarget: DisplayIdentity?
    @Published private(set) var effectiveTarget: DisplayIdentity?
    @Published private(set) var dockLocation: DisplayIdentity?
    @Published private(set) var status: DockPriorityStatus = .idle

    private let inventory: DisplayInventory
    private let locator: DockLocating
    private let relocator: DockRelocating
    private let store: DisplayPriorityStoring
    private let watchdogScheduler: WatchdogScheduling
    private let eventTapController: EventTapControlling
    private let dockEdgeProvider: DockEdgeProviding
    private let reconciliationDelay: @Sendable (Duration) async throws -> Void
    private let logger = Logger(
        subsystem: "io.github.cinestill800t.DockPriority",
        category: "coordinator"
    )

    private var generation: UInt64 = 0
    private var reconciliationTask: Task<Void, Never>?
    private var persistenceFailure: String?

    init(
        inventory: DisplayInventory,
        locator: DockLocating,
        relocator: DockRelocating,
        store: DisplayPriorityStoring,
        watchdogScheduler: WatchdogScheduling,
        eventTapController: EventTapControlling,
        dockEdgeProvider: DockEdgeProviding = AccessibilityDockEdgeProvider(),
        reconciliationDelay: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.inventory = inventory
        self.locator = locator
        self.relocator = relocator
        self.store = store
        self.watchdogScheduler = watchdogScheduler
        self.eventTapController = eventTapController
        self.dockEdgeProvider = dockEdgeProvider
        self.reconciliationDelay = reconciliationDelay

        do {
            rememberedDisplays = try store.load()?.normalized().orderedDisplays ?? []
        } catch {
            rememberedDisplays = []
            persistenceFailure = Self.description(of: error)
            status = .persistenceFailed(Self.description(of: error))
        }

        inventory.startObserving { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.handleDisplayChange(reason)
            }
        }
    }

    static func live() -> DockPriorityCoordinator {
        let eventTapController = CGEventTapController()
        return DockPriorityCoordinator(
            inventory: SystemDisplayInventory(),
            locator: AccessibilityDockLocator(),
            relocator: CGEventDockRelocator(eventTapController: eventTapController),
            store: UserDefaultsDisplayPriorityStore(),
            watchdogScheduler: TimerWatchdogScheduler(),
            eventTapController: eventTapController,
            dockEdgeProvider: AccessibilityDockEdgeProvider()
        )
    }

    func refresh() {
        enqueue(.refresh)
    }

    func start() {
        startProtection()
    }

    func stop() {
        stopProtection()
    }

    func setProtectionEnabled(_ enabled: Bool) {
        enabled ? startProtection() : stopProtection()
    }

    func startProtection() {
        guard !protectionState.isActive else { return }

        do {
            try eventTapController.start { _ in .passThrough }
        } catch {
            invalidatePendingWork()
            status = Self.status(for: error, operation: .eventTap)
            return
        }

        protectionState = .active
        watchdogScheduler.start(interval: .seconds(5)) { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.protectionState.isActive == true else { return }
                self?.enqueue(.watchdog)
            }
        }
        enqueue(.protectionStarted)
    }

    func stopProtection() {
        protectionState = .stopped
        watchdogScheduler.stop()
        eventTapController.stop()
        enqueue(.protectionStopped)
    }

    func movePriority(_ offsets: IndexSet, _ destination: Int) {
        movePriority(fromOffsets: offsets, toOffset: destination)
    }

    func movePriority(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty else { return }
        let validOffsets = offsets.filter(rememberedDisplays.indices.contains)
        guard !validOffsets.isEmpty else { return }

        let moving = validOffsets.sorted().map { rememberedDisplays[$0] }
        for index in validOffsets.sorted(by: >) {
            rememberedDisplays.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            rememberedDisplays.count
        )
        rememberedDisplays.insert(contentsOf: moving, at: insertionIndex)
        persistCurrentPriority()
        enqueue(.priorityChanged)
    }

    func movePriorityUp(_ identity: DisplayIdentity) {
        guard let index = rememberedDisplays.firstIndex(where: { $0.identity == identity }),
              index > 0 else { return }
        rememberedDisplays.swapAt(index, index - 1)
        persistCurrentPriority()
        enqueue(.priorityChanged)
    }

    func movePriorityDown(_ identity: DisplayIdentity) {
        guard let index = rememberedDisplays.firstIndex(where: { $0.identity == identity }),
              index < rememberedDisplays.index(before: rememberedDisplays.endIndex) else { return }
        rememberedDisplays.swapAt(index, index + 1)
        persistCurrentPriority()
        enqueue(.priorityChanged)
    }

    func selectTemporaryTarget(_ identity: DisplayIdentity) {
        chooseTemporaryTarget(identity)
    }

    func chooseTemporaryTarget(_ identity: DisplayIdentity) {
        guard activeDisplays.contains(where: { $0.identity == identity }) else {
            status = .noAvailableDisplays
            return
        }
        temporaryTarget = identity
        enqueue(.temporarySelected)
    }

    func returnToPriority() {
        temporaryTarget = nil
        enqueue(.returnToPriority)
    }

    func handleDisplayChange(_ reason: DisplayChangeReason) {
        // Every display/power reason immediately invalidates an explicit
        // temporary choice and any work based on the old display topology.
        // Raw CG/AppKit events can arrive in bursts while frames and modes are
        // inconsistent, so inventory and relocation wait for the single
        // debounced `configurationSettled` event.
        temporaryTarget = nil
        invalidatePendingWork()
        updateEffectiveTargetFromCurrentState()

        guard reason.triggersInventoryRefresh else { return }
        enqueue(.displayChange(reason))
    }

    /// Test-only synchronization seam. It is harmless in production and waits
    /// for the latest coalesced request, including any predecessor it replaced.
    func waitForIdle() async {
        await reconciliationTask?.value
    }

    private func enqueue(_ reason: ReconcileReason) {
        generation &+= 1
        let requestGeneration = generation
        let predecessor = reconciliationTask
        predecessor?.cancel()

        reconciliationTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self,
                  !Task.isCancelled,
                  generation == requestGeneration else { return }
            await reconcile(reason: reason, requestGeneration: requestGeneration)
        }
    }

    private func invalidatePendingWork() {
        generation &+= 1
        reconciliationTask?.cancel()
    }

    private func reconcile(reason: ReconcileReason, requestGeneration: UInt64) async {
        let displays: [DisplaySnapshot]
        do {
            displays = try inventory.activeDisplays()
        } catch {
            guard isCurrent(requestGeneration) else { return }
            if reason.clearsTemporaryTarget {
                temporaryTarget = nil
            }
            activeDisplays = []
            effectiveTarget = nil
            dockLocation = nil
            status = .inventoryFailed(Self.description(of: error))
            return
        }

        guard isCurrent(requestGeneration) else { return }
        activeDisplays = Self.uniqueDisplays(displays)
        mergeRememberedDisplays(with: activeDisplays)

        if reason.clearsTemporaryTarget {
            temporaryTarget = nil
        }

        let activeByIdentity = Dictionary(
            uniqueKeysWithValues: activeDisplays.map { ($0.identity, $0) }
        )
        if let temporaryTarget, activeByIdentity[temporaryTarget] == nil {
            self.temporaryTarget = nil
        }

        let normalTarget = rememberedDisplays.lazy
            .compactMap { activeByIdentity[$0.identity] }
            .first
        let target = temporaryTarget.flatMap { activeByIdentity[$0] } ?? normalTarget
        effectiveTarget = target?.identity

        if protectionState.isActive {
            updateMovementGuard(targetIdentity: target?.identity)
        }

        guard let target else {
            dockLocation = nil
            status = persistenceStatus ?? .noAvailableDisplays
            return
        }

        let shouldMove = protectionState.isActive || reason.isManualOneShot
        guard shouldMove else {
            status = persistenceStatus ?? .protectionStopped
            return
        }

        do {
            let currentLocation = try await locator.dockDisplay(in: activeDisplays)
            guard isCurrent(requestGeneration, target: target.identity) else { return }
            dockLocation = currentLocation
            if currentLocation == target.identity {
                status = persistenceStatus ?? .targetReady
                return
            }
        } catch {
            guard isCurrent(requestGeneration, target: target.identity) else { return }
            dockLocation = nil
            if Self.isAccessibilityFailure(error) {
                status = .accessibilityPermissionRequired
                return
            }
            guard Self.isRecoverableDockFrameFailure(error) else {
                status = .dockLocationFailed(Self.description(of: error))
                return
            }
            // An unknown/unavailable Dock location is recoverable: make one
            // relocation attempt, then verify it instead of spinning here.
            logger.error("Dock location unavailable before relocation: \(Self.description(of: error), privacy: .public)")
        }

        await relocateAndVerify(target, requestGeneration: requestGeneration)
    }

    /// Performs no more than two independent cursor-restoring gestures. The
    /// relocator owns its short-lived event-tap bypass; this coordinator never
    /// leaves that bypass active while waiting for Dock mode changes to settle.
    private func relocateAndVerify(_ target: DisplaySnapshot, requestGeneration: UInt64) async {
        for (attempt, delay) in [(1, Duration.milliseconds(500)), (2, Duration.milliseconds(250))] {
            guard isCurrent(requestGeneration, target: target.identity) else { return }
            do {
                try await relocator.relocate(to: target)
            } catch {
                guard isCurrent(requestGeneration, target: target.identity) else { return }
                if attempt == 1, Self.isRecoverableDockFrameFailure(error) {
                    continue
                }
                applyRelocationFailure(error, requestGeneration: requestGeneration, target: target.identity)
                return
            }

            guard isCurrent(requestGeneration, target: target.identity) else { return }
            do {
                try await reconciliationDelay(delay)
            } catch {
                return
            }
            guard isCurrent(requestGeneration, target: target.identity) else { return }

            do {
                let verifiedLocation = try await locator.dockDisplay(in: activeDisplays)
                guard isCurrent(requestGeneration, target: target.identity) else { return }
                dockLocation = verifiedLocation
                if verifiedLocation == target.identity {
                    status = persistenceStatus ?? .moved(target.identity)
                    return
                }
                if attempt == 2 {
                    status = .relocationFailed("The Dock move could not be verified.")
                    return
                }
            } catch {
                guard isCurrent(requestGeneration, target: target.identity) else { return }
                if Self.isAccessibilityFailure(error) {
                    status = .accessibilityPermissionRequired
                    return
                }
                if !Self.isRecoverableDockFrameFailure(error) || attempt == 2 {
                    status = .relocationFailed(Self.description(of: error))
                    return
                }
            }
        }
    }

    private func applyRelocationFailure(
        _ error: Error,
        requestGeneration: UInt64,
        target: DisplayIdentity
    ) {
        guard isCurrent(requestGeneration, target: target) else { return }
        if Self.isAccessibilityFailure(error) {
            status = .accessibilityPermissionRequired
        } else if !(error is CancellationError) {
            let message = Self.description(of: error)
            logger.error("Dock relocation failed: \(message, privacy: .public)")
            status = .relocationFailed(message)
        }
    }

    private func mergeRememberedDisplays(with displays: [DisplaySnapshot]) {
        var updated = StoredPriorityState(orderedDisplays: rememberedDisplays).normalized().orderedDisplays
        let startingValue = updated
        let displaysByIdentity = Dictionary(uniqueKeysWithValues: displays.map { ($0.identity, $0) })

        for index in updated.indices {
            if let active = displaysByIdentity[updated[index].identity],
               updated[index].lastKnownName != active.name {
                updated[index].lastKnownName = active.name
            }
        }

        let known = Set(updated.map(\.identity))
        let newDisplays = displays
            .filter { !known.contains($0.identity) }
            .sorted(by: Self.initialDisplayOrder)
        updated.append(contentsOf: newDisplays.map {
            RememberedDisplay(identity: $0.identity, lastKnownName: $0.name)
        })

        rememberedDisplays = updated
        if updated != startingValue {
            persistCurrentPriority()
        }
    }

    private func persistCurrentPriority() {
        do {
            try store.save(StoredPriorityState(orderedDisplays: rememberedDisplays))
            persistenceFailure = nil
        } catch {
            let message = Self.description(of: error)
            persistenceFailure = message
            status = .persistenceFailed(message)
            logger.error("Display priority persistence failed: \(message, privacy: .public)")
        }
    }

    private func updateMovementGuard(targetIdentity: DisplayIdentity?) {
        let edge = (try? dockEdgeProvider.currentDockEdge()) ?? .bottom
        let movementGuard = DockMovementGuard(
            targetIdentity: targetIdentity,
            activeDisplays: activeDisplays,
            edge: edge
        )
        do {
            try eventTapController.start { event in
                return movementGuard.disposition(for: event)
            }
        } catch {
            status = Self.status(for: error, operation: .eventTap)
        }
    }

    private func updateEffectiveTargetFromCurrentState() {
        let activeByIdentity = Dictionary(
            uniqueKeysWithValues: activeDisplays.map { ($0.identity, $0) }
        )
        effectiveTarget = rememberedDisplays.lazy
            .compactMap { activeByIdentity[$0.identity] }
            .first?.identity
    }

    private var persistenceStatus: DockPriorityStatus? {
        persistenceFailure.map(DockPriorityStatus.persistenceFailed)
    }

    private func isCurrent(_ requestGeneration: UInt64, target: DisplayIdentity? = nil) -> Bool {
        guard !Task.isCancelled, generation == requestGeneration else { return false }
        return target == nil || effectiveTarget == target
    }

    private static func uniqueDisplays(_ displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
        var seen = Set<DisplayIdentity>()
        return displays.filter { seen.insert($0.identity).inserted }
    }

    private static func initialDisplayOrder(_ lhs: DisplaySnapshot, _ rhs: DisplaySnapshot) -> Bool {
        if lhs.isMain != rhs.isMain { return lhs.isMain }
        if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
        if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
        return lhs.identity.stableDescription < rhs.identity.stableDescription
    }

    private enum ErrorOperation {
        case eventTap
    }

    private static func status(for error: Error, operation: ErrorOperation) -> DockPriorityStatus {
        if isAccessibilityFailure(error) { return .accessibilityPermissionRequired }
        switch operation {
        case .eventTap:
            return .dockLocationFailed(description(of: error))
        }
    }

    private static func isAccessibilityFailure(_ error: Error) -> Bool {
        if let error = error as? DockLocationError,
           error == .accessibilityPermissionDenied { return true }
        if let error = error as? DockRelocationError,
           error == .accessibilityPermissionDenied { return true }
        if let error = error as? EventTapControllerError,
           error == .accessibilityPermissionDenied { return true }
        return false
    }

    private static func isRecoverableDockFrameFailure(_ error: Error) -> Bool {
        if let error = error as? DockLocationError,
           error == .dockFrameUnavailable { return true }
        if let error = error as? DockRelocationError,
           error == .dockFrameUnavailable { return true }
        return false
    }

    private static func description(of error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
