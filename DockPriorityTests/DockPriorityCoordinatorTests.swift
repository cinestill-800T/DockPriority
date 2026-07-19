import CoreGraphics
import Foundation
import Testing
@testable import DockPriority

@MainActor
struct DockPriorityCoordinatorTests {
    @Test func firstStartupOrdersMainThenGeometryAndPersists() async {
        let left = snapshot("left", name: "Left", x: -1000)
        let main = snapshot("main", name: "Main", x: 1000, isMain: true)
        let lower = snapshot("lower", name: "Lower", x: 0, y: 500)
        let upper = snapshot("upper", name: "Upper", x: 0, y: -500)
        let harness = makeHarness(displays: [lower, left, main, upper])

        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()

        #expect(harness.coordinator.rememberedDisplays.map(\.identity) == [
            main.identity, left.identity, upper.identity, lower.identity
        ])
        #expect(harness.store.savedStates.last?.orderedDisplays == harness.coordinator.rememberedDisplays)
        #expect(harness.relocator.targets.isEmpty)
    }

    @Test func noActiveDisplaysProducesNoTargetOrMove() async {
        let harness = makeHarness(displays: [])

        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()

        #expect(harness.coordinator.activeDisplays.isEmpty)
        #expect(harness.coordinator.effectiveTarget == nil)
        #expect(harness.coordinator.status == .noAvailableDisplays)
        #expect(harness.relocator.targets.isEmpty)
    }

    @Test func newDisplaysAppendAndDisconnectedEntriesRemainRemembered() async {
        let first = snapshot("first", name: "Old Name", isMain: true)
        let missing = remembered("missing", name: "Disconnected")
        let store = FakeStore(state: StoredPriorityState(orderedDisplays: [
            remembered("first", name: "Old Name"), missing
        ]))
        let harness = makeHarness(displays: [first], store: store)

        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()
        harness.inventory.displays = [
            snapshot("first", name: "Renamed", isMain: true),
            snapshot("new", name: "New", x: -1000)
        ]
        harness.inventory.emit(.displayAdded)
        harness.inventory.emit(.configurationSettled)
        await settle(harness.coordinator)

        #expect(harness.coordinator.rememberedDisplays.map(\.identity) == [
            identity("first"), identity("missing"), identity("new")
        ])
        #expect(harness.coordinator.rememberedDisplays[0].lastKnownName == "Renamed")
        #expect(harness.coordinator.rememberedDisplays[1] == missing)
    }

    @Test func disconnectFallsBackAndReconnectRestoresHigherPriority() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )

        harness.coordinator.startProtection()
        await harness.coordinator.waitForIdle()
        #expect(harness.coordinator.effectiveTarget == first.identity)

        harness.inventory.displays = [second]
        harness.inventory.emit(.displayRemoved)
        harness.inventory.emit(.configurationSettled)
        await settle(harness.coordinator)
        #expect(harness.coordinator.effectiveTarget == second.identity)
        #expect(harness.relocator.targets.last == second.identity)

        harness.inventory.displays = [first, second]
        harness.inventory.emit(.displayAdded)
        harness.inventory.emit(.configurationSettled)
        await settle(harness.coordinator)
        #expect(harness.coordinator.effectiveTarget == first.identity)
        #expect(harness.relocator.targets.last == first.identity)
        #expect(harness.coordinator.rememberedDisplays.map(\.identity) == [first.identity, second.identity])
    }

    @Test func temporaryTargetOverridesPriorityAndReorderDoesNotClearIt() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )
        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()

        harness.coordinator.chooseTemporaryTarget(second.identity)
        await harness.coordinator.waitForIdle()
        harness.coordinator.movePriorityDown(first.identity)
        await harness.coordinator.waitForIdle()

        #expect(harness.coordinator.temporaryTarget == second.identity)
        #expect(harness.coordinator.effectiveTarget == second.identity)
        #expect(harness.coordinator.rememberedDisplays.map(\.identity) == [second.identity, first.identity])
        #expect(harness.store.savedStates.last?.orderedDisplays.map(\.identity) == [second.identity, first.identity])
    }

    @Test(arguments: DisplayChangeReason.allCases)
    func everyDisplayAndPowerEventClearsTemporaryTarget(reason: DisplayChangeReason) async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )
        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()
        harness.coordinator.chooseTemporaryTarget(second.identity)
        await harness.coordinator.waitForIdle()

        harness.inventory.emit(reason)
        await settle(harness.coordinator)

        #expect(harness.coordinator.temporaryTarget == nil)
        #expect(harness.coordinator.effectiveTarget == first.identity)
    }

    @Test func rawConfigurationBurstWaitsForSingleSettledRefreshAndMove() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )
        harness.coordinator.startProtection()
        await harness.coordinator.waitForIdle()
        harness.coordinator.chooseTemporaryTarget(second.identity)
        await harness.coordinator.waitForIdle()

        let inventoryCallsBeforeBurst = harness.inventory.activeDisplayCallCount
        let locatorCallsBeforeBurst = harness.locator.callCount
        let movesBeforeBurst = harness.relocator.targets.count

        harness.inventory.emit(.reconfigurationBegan)
        harness.inventory.emit(.displayModeChanged)
        harness.inventory.emit(.screenParametersChanged)
        await settle(harness.coordinator)

        #expect(harness.coordinator.temporaryTarget == nil)
        #expect(harness.inventory.activeDisplayCallCount == inventoryCallsBeforeBurst)
        #expect(harness.locator.callCount == locatorCallsBeforeBurst)
        #expect(harness.relocator.targets.count == movesBeforeBurst)

        harness.inventory.emit(.configurationSettled)
        await settle(harness.coordinator)

        #expect(harness.inventory.activeDisplayCallCount == inventoryCallsBeforeBurst + 1)
        #expect(harness.relocator.targets.count == movesBeforeBurst + 1)
        #expect(harness.relocator.targets.last == first.identity)
    }

    @Test func sleepOnlyInvalidatesWhileWakeAndUnlockReconcile() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )
        harness.coordinator.startProtection()
        await harness.coordinator.waitForIdle()
        harness.coordinator.chooseTemporaryTarget(second.identity)
        await harness.coordinator.waitForIdle()

        let callsBeforeSleep = harness.inventory.activeDisplayCallCount
        let movesBeforeSleep = harness.relocator.targets.count
        harness.inventory.emit(.systemSleep)
        await settle(harness.coordinator)

        #expect(harness.coordinator.temporaryTarget == nil)
        #expect(harness.inventory.activeDisplayCallCount == callsBeforeSleep)
        #expect(harness.relocator.targets.count == movesBeforeSleep)

        harness.inventory.emit(.systemWake)
        await settle(harness.coordinator)
        #expect(harness.inventory.activeDisplayCallCount == callsBeforeSleep + 1)
        #expect(harness.relocator.targets.last == first.identity)

        harness.coordinator.chooseTemporaryTarget(second.identity)
        await harness.coordinator.waitForIdle()
        let callsBeforeUnlock = harness.inventory.activeDisplayCallCount
        harness.inventory.emit(.screenUnlocked)
        await settle(harness.coordinator)
        #expect(harness.coordinator.temporaryTarget == nil)
        #expect(harness.inventory.activeDisplayCallCount == callsBeforeUnlock + 1)
        #expect(harness.relocator.targets.last == first.identity)
    }

    @Test func stoppedModeOnlyMovesForTemporaryAndReturnOneShots() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )
        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()

        harness.inventory.emit(.displayModeChanged)
        await settle(harness.coordinator)
        harness.coordinator.movePriorityDown(first.identity)
        await harness.coordinator.waitForIdle()
        #expect(harness.relocator.targets.isEmpty)

        harness.locator.current = second.identity
        harness.coordinator.chooseTemporaryTarget(first.identity)
        await harness.coordinator.waitForIdle()
        #expect(harness.relocator.targets == [first.identity])

        harness.coordinator.returnToPriority()
        await harness.coordinator.waitForIdle()
        #expect(harness.relocator.targets == [first.identity, second.identity])
        #expect(harness.coordinator.temporaryTarget == nil)
    }

    @Test func watchdogMaintainsTemporaryTargetAndOnlyCorrectsDrift() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )
        harness.coordinator.startProtection()
        await harness.coordinator.waitForIdle()
        #expect(harness.scheduler.intervals == [.seconds(5)])

        harness.coordinator.chooseTemporaryTarget(second.identity)
        await harness.coordinator.waitForIdle()
        let movesAfterSelection = harness.relocator.targets.count

        harness.scheduler.fire()
        await settle(harness.coordinator)
        #expect(harness.relocator.targets.count == movesAfterSelection)
        #expect(harness.coordinator.temporaryTarget == second.identity)

        harness.locator.current = first.identity
        harness.scheduler.fire()
        await settle(harness.coordinator)
        #expect(harness.relocator.targets.last == second.identity)

        harness.coordinator.stopProtection()
        await harness.coordinator.waitForIdle()
        let movesAfterStop = harness.relocator.targets.count
        harness.locator.current = first.identity
        harness.scheduler.fire()
        await settle(harness.coordinator)
        #expect(harness.relocator.targets.count == movesAfterStop)
        #expect(harness.scheduler.stopCount >= 1)
    }

    @Test func protectionSuppressesNonTargetDockEdgeWithoutStaticMarkerBypass() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )

        harness.coordinator.startProtection()
        await harness.coordinator.waitForIdle()

        #expect(harness.eventTap.disposition(at: CGPoint(x: 1500, y: 799)) == .suppress)
        #expect(harness.eventTap.disposition(at: CGPoint(x: 500, y: 799)) == .passThrough)
        #expect(harness.eventTap.disposition(
            at: CGPoint(x: 1500, y: 799),
            sourceUserData: 0x4450_5249
        ) == .suppress)

        harness.coordinator.stopProtection()
        await harness.coordinator.waitForIdle()
        #expect(!harness.eventTap.isRunning)
        #expect(harness.eventTap.disposition(at: CGPoint(x: 1500, y: 799)) == .passThrough)
    }

    @Test func deniedEventTapDoesNotActivateProtectionOrWatchdog() async {
        let display = snapshot("first", isMain: true)
        let harness = makeHarness(
            displays: [display],
            state: priorityState([display]),
            dockLocation: display.identity
        )
        harness.eventTap.startError = EventTapControllerError.accessibilityPermissionDenied

        harness.coordinator.startProtection()
        await harness.coordinator.waitForIdle()

        #expect(harness.coordinator.protectionState == .stopped)
        #expect(harness.coordinator.status == .accessibilityPermissionRequired)
        #expect(harness.scheduler.intervals.isEmpty)
    }

    @Test func staleLocatorResultCannotMoveOldTemporaryTarget() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let locator = FakeLocator(current: first.identity)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            locator: locator
        )
        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()

        locator.suspendNextCall = true
        harness.coordinator.chooseTemporaryTarget(second.identity)
        await waitUntil { locator.pendingContinuation != nil }
        harness.inventory.displays = [first]
        harness.inventory.emit(.displayRemoved)
        await Task.yield()
        locator.resumePending(returning: first.identity)
        await settle(harness.coordinator)

        #expect(harness.coordinator.temporaryTarget == nil)
        #expect(harness.coordinator.effectiveTarget == first.identity)
        #expect(harness.relocator.targets.isEmpty)
    }

    @Test func queuedRelocationsNeverOverlapAndNewestTargetWins() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let relocator = FakeRelocator()
        relocator.suspendNextCall = true
        let locator = FakeLocator(current: first.identity)
        relocator.locator = locator
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            locator: locator,
            relocator: relocator
        )
        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()

        harness.coordinator.chooseTemporaryTarget(second.identity)
        await waitUntil { relocator.pendingContinuation != nil }
        harness.coordinator.returnToPriority()
        await Task.yield()
        relocator.resumePending()
        await settle(harness.coordinator)

        #expect(relocator.maximumConcurrentCalls == 1)
        #expect(relocator.targets == [second.identity, first.identity])
        #expect(harness.coordinator.effectiveTarget == first.identity)
        #expect(harness.coordinator.dockLocation == first.identity)
    }

    @Test func failuresKeepPolicyAndExposeActionableStatus() async {
        let display = snapshot("first", isMain: true)
        let failingStore = FakeStore(saveError: FakeError.persistence)
        let persistenceHarness = makeHarness(displays: [display], store: failingStore)
        persistenceHarness.coordinator.refresh()
        await persistenceHarness.coordinator.waitForIdle()
        #expect(persistenceHarness.coordinator.rememberedDisplays.map(\.identity) == [display.identity])
        #expect(persistenceHarness.coordinator.status == .persistenceFailed("Persistence failed"))

        let inventoryHarness = makeHarness(displays: [display])
        inventoryHarness.inventory.error = FakeError.inventory
        inventoryHarness.coordinator.refresh()
        await inventoryHarness.coordinator.waitForIdle()
        #expect(inventoryHarness.coordinator.activeDisplays.isEmpty)
        #expect(inventoryHarness.coordinator.status == .inventoryFailed("Inventory failed"))

        let deniedLocator = FakeLocator(current: nil)
        deniedLocator.errors = [DockLocationError.accessibilityPermissionDenied]
        let permissionHarness = makeHarness(
            displays: [display],
            state: priorityState([display]),
            locator: deniedLocator
        )
        permissionHarness.coordinator.startProtection()
        await permissionHarness.coordinator.waitForIdle()
        #expect(permissionHarness.coordinator.status == .accessibilityPermissionRequired)
        #expect(permissionHarness.relocator.targets.isEmpty)
    }

    @Test func displayEventClearsTemporaryTargetEvenWhenInventoryRefreshFails() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity
        )
        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()
        harness.coordinator.chooseTemporaryTarget(second.identity)
        await harness.coordinator.waitForIdle()

        harness.inventory.error = FakeError.inventory
        harness.inventory.emit(.displayModeChanged)
        await settle(harness.coordinator)

        #expect(harness.coordinator.temporaryTarget == nil)
        #expect(!harness.coordinator.activeDisplays.isEmpty)

        harness.inventory.emit(.configurationSettled)
        await settle(harness.coordinator)

        #expect(harness.coordinator.activeDisplays.isEmpty)
        #expect(harness.coordinator.status == .inventoryFailed("Inventory failed"))
    }

    @Test func relocationFailurePreservesTemporarySelectionForRetry() async {
        let first = snapshot("first", isMain: true)
        let second = snapshot("second", x: 1000)
        let relocator = FakeRelocator()
        relocator.error = FakeError.relocation
        let harness = makeHarness(
            displays: [first, second],
            state: priorityState([first, second]),
            dockLocation: first.identity,
            relocator: relocator
        )
        harness.coordinator.refresh()
        await harness.coordinator.waitForIdle()
        harness.coordinator.chooseTemporaryTarget(second.identity)
        await harness.coordinator.waitForIdle()

        #expect(harness.coordinator.temporaryTarget == second.identity)
        #expect(harness.coordinator.status == .relocationFailed("Relocation failed"))
    }

    private func makeHarness(
        displays: [DisplaySnapshot],
        state: StoredPriorityState? = nil,
        dockLocation: DisplayIdentity? = nil,
        store: FakeStore? = nil,
        locator: FakeLocator? = nil,
        relocator: FakeRelocator? = nil
    ) -> Harness {
        let inventory = FakeInventory(displays: displays)
        let store = store ?? FakeStore(state: state)
        let locator = locator ?? FakeLocator(current: dockLocation)
        let relocator = relocator ?? FakeRelocator()
        relocator.locator = locator
        let scheduler = FakeWatchdogScheduler()
        let eventTap = FakeEventTapController()
        let coordinator = DockPriorityCoordinator(
            inventory: inventory,
            locator: locator,
            relocator: relocator,
            store: store,
            watchdogScheduler: scheduler,
            eventTapController: eventTap,
            dockEdgeProvider: FakeDockEdgeProvider(edge: .bottom)
        )
        return Harness(
            coordinator: coordinator,
            inventory: inventory,
            locator: locator,
            relocator: relocator,
            store: store,
            scheduler: scheduler,
            eventTap: eventTap
        )
    }

    private func settle(_ coordinator: DockPriorityCoordinator) async {
        await Task.yield()
        await Task.yield()
        await coordinator.waitForIdle()
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 where !predicate() {
            await Task.yield()
        }
        #expect(predicate())
    }
}

@MainActor
private struct Harness {
    let coordinator: DockPriorityCoordinator
    let inventory: FakeInventory
    let locator: FakeLocator
    let relocator: FakeRelocator
    let store: FakeStore
    let scheduler: FakeWatchdogScheduler
    let eventTap: FakeEventTapController
}

private enum FakeError: Error, LocalizedError {
    case inventory
    case persistence
    case relocation

    var errorDescription: String? {
        switch self {
        case .inventory: "Inventory failed"
        case .persistence: "Persistence failed"
        case .relocation: "Relocation failed"
        }
    }
}

private final class FakeInventory: DisplayInventory, @unchecked Sendable {
    var displays: [DisplaySnapshot]
    var error: Error?
    private(set) var activeDisplayCallCount = 0
    private(set) var handler: (@Sendable (DisplayChangeReason) -> Void)?

    init(displays: [DisplaySnapshot]) {
        self.displays = displays
    }

    func activeDisplays() throws -> [DisplaySnapshot] {
        activeDisplayCallCount += 1
        if let error { throw error }
        return displays
    }

    func startObserving(_ handler: @escaping @Sendable (DisplayChangeReason) -> Void) {
        self.handler = handler
    }

    func stopObserving() {
        handler = nil
    }

    func emit(_ reason: DisplayChangeReason) {
        handler?(reason)
    }
}

private final class FakeLocator: DockLocating, @unchecked Sendable {
    var current: DisplayIdentity?
    var errors: [Error] = []
    var suspendNextCall = false
    private(set) var callCount = 0
    private(set) var pendingContinuation: CheckedContinuation<DisplayIdentity?, Error>?

    init(current: DisplayIdentity?) {
        self.current = current
    }

    func dockDisplay(in _: [DisplaySnapshot]) async throws -> DisplayIdentity? {
        callCount += 1
        if !errors.isEmpty { throw errors.removeFirst() }
        if suspendNextCall {
            suspendNextCall = false
            return try await withCheckedThrowingContinuation { continuation in
                pendingContinuation = continuation
            }
        }
        return current
    }

    func resumePending(returning identity: DisplayIdentity?) {
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(returning: identity)
    }
}

private final class FakeRelocator: DockRelocating, @unchecked Sendable {
    weak var locator: FakeLocator?
    var error: Error?
    var suspendNextCall = false
    private(set) var targets: [DisplayIdentity] = []
    private(set) var concurrentCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var pendingContinuation: CheckedContinuation<Void, Never>?

    func relocate(to display: DisplaySnapshot) async throws {
        concurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
        targets.append(display.identity)
        defer { concurrentCalls -= 1 }
        if let error { throw error }
        if suspendNextCall {
            suspendNextCall = false
            await withCheckedContinuation { continuation in
                pendingContinuation = continuation
            }
        }
        locator?.current = display.identity
    }

    func resumePending() {
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume()
    }
}

private final class FakeStore: DisplayPriorityStoring {
    var state: StoredPriorityState?
    var loadError: Error?
    var saveError: Error?
    private(set) var savedStates: [StoredPriorityState] = []

    init(
        state: StoredPriorityState? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil
    ) {
        self.state = state
        self.loadError = loadError
        self.saveError = saveError
    }

    func load() throws -> StoredPriorityState? {
        if let loadError { throw loadError }
        return state
    }

    func save(_ state: StoredPriorityState) throws {
        if let saveError { throw saveError }
        self.state = state
        savedStates.append(state)
    }
}

private final class FakeWatchdogScheduler: WatchdogScheduling {
    private(set) var intervals: [Duration] = []
    private(set) var stopCount = 0
    private var tick: (@Sendable () -> Void)?

    func start(interval: Duration, tick: @escaping @Sendable () -> Void) {
        intervals.append(interval)
        self.tick = tick
    }

    func stop() {
        stopCount += 1
        tick = nil
    }

    func fire() {
        tick?()
    }
}

private final class FakeEventTapController: EventTapControlling {
    var isRunning = false
    var startError: Error?
    private(set) var relocationStates: [Bool] = []
    private var handler: (@Sendable (MouseEventSnapshot) -> MouseEventDisposition)?

    func start(handler: @escaping @Sendable (MouseEventSnapshot) -> MouseEventDisposition) throws {
        if let startError { throw startError }
        isRunning = true
        self.handler = handler
    }

    func stop() {
        isRunning = false
        handler = nil
    }

    func setRelocationActive(_ active: Bool) {
        relocationStates.append(active)
    }

    func disposition(at point: CGPoint, sourceUserData: Int64 = 0) -> MouseEventDisposition {
        guard isRunning else { return .passThrough }
        return handler?(MouseEventSnapshot(location: point, sourceUserData: sourceUserData)) ?? .passThrough
    }
}

private struct FakeDockEdgeProvider: DockEdgeProviding {
    let edge: DockEdge

    func currentDockEdge() throws -> DockEdge { edge }
}

private func identity(_ value: String) -> DisplayIdentity {
    .cgUUID(value)
}

private func remembered(_ value: String, name: String? = nil) -> RememberedDisplay {
    RememberedDisplay(identity: identity(value), lastKnownName: name ?? value.capitalized)
}

private func priorityState(_ displays: [DisplaySnapshot]) -> StoredPriorityState {
    StoredPriorityState(orderedDisplays: displays.map {
        RememberedDisplay(identity: $0.identity, lastKnownName: $0.name)
    })
}

private func snapshot(
    _ value: String,
    name: String? = nil,
    x: CGFloat = 0,
    y: CGFloat = 0,
    isMain: Bool = false
) -> DisplaySnapshot {
    let frame = CGRect(x: x, y: y, width: 1000, height: 800)
    return DisplaySnapshot(
        runtimeID: CGDirectDisplayID(abs(value.hashValue % 10_000) + 1),
        identity: identity(value),
        name: name ?? value.capitalized,
        frame: frame,
        isMain: isMain,
        isBuiltIn: false,
        modeSignature: DisplayModeSignature(
            pixelWidth: 1000,
            pixelHeight: 800,
            logicalWidth: 1000,
            logicalHeight: 800,
            refreshRate: 60,
            frame: frame,
            rotation: 0,
            isMain: isMain,
            isMirrored: false
        )
    )
}
