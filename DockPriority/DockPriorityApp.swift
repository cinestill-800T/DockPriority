import SwiftUI

@main
struct DockPriorityApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: ApplicationDelegate
    @StateObject private var coordinator: DockPriorityCoordinator
    @StateObject private var appSettings: AppSettings
    @StateObject private var updateChecker = UpdateChecker.shared
    private let isRunningUnitTests: Bool
    private let isRunningUITests: Bool

    init() {
        let settings: AppSettings
        let coordinator: DockPriorityCoordinator
        var isRunningUITests = false

#if DEBUG
        if let fixture = UITestFixture.current {
            isRunningUITests = true
            settings = AppSettings(
                defaults: fixture.makeSettingsDefaults(),
                sideEffectsEnabled: false
            )
            coordinator = fixture.makeCoordinator()
        } else {
            settings = AppSettings.shared
            coordinator = Self.makeLiveCoordinator()
        }
#else
        settings = AppSettings.shared
        coordinator = Self.makeLiveCoordinator()
#endif

        self.isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.isRunningUITests = isRunningUITests
        _appSettings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: coordinator)
        appDelegate.coordinator = coordinator
        appDelegate.appSettings = settings
    }

    private static func makeLiveCoordinator() -> DockPriorityCoordinator {
        let eventTapController = CGEventTapController()
        return DockPriorityCoordinator(
            inventory: SystemDisplayInventory(),
            locator: AccessibilityDockLocator(),
            relocator: CGEventDockRelocator(
                eventTapController: eventTapController,
                configurationProvider: { DockRelocationSettings.shared.configuration }
            ),
            store: UserDefaultsDisplayPriorityStore(),
            watchdogScheduler: TimerWatchdogScheduler(),
            eventTapController: eventTapController,
            dockEdgeProvider: AccessibilityDockEdgeProvider()
        )
    }

    var body: some Scene {
        WindowGroup("DockPriority") {
            if isRunningUnitTests && !isRunningUITests {
                Color.clear.frame(width: 1, height: 1)
            } else {
                ContentView()
                    .environmentObject(coordinator)
                    .environmentObject(appSettings)
                    .preferredColorScheme(appSettings.appTheme.colorScheme)
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Show DockPriority") { openMainWindow() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                Button(coordinator.protectionState.isActive ? "Stop Protection" : "Start Protection") {
                    coordinator.setProtectionEnabled(!coordinator.protectionState.isActive)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }

        MenuBarExtra(
            "DockPriority",
            systemImage: coordinator.protectionState.isActive ? "shield.checkered" : "dock.rectangle",
            isInserted: menuBarIconInsertionBinding
        ) {
            MenuBarContents()
                .environmentObject(coordinator)
                .environmentObject(updateChecker)
        }
    }

    private var menuBarIconInsertionBinding: Binding<Bool> {
        guard !isRunningUnitTests, !isRunningUITests else {
            return .constant(false)
        }
        return Binding(
            get: { appSettings.showStatusIcon },
            set: { appSettings.requestMenuBarIconVisibility($0) }
        )
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible || $0.frame.width > 100 })?.makeKeyAndOrderFront(nil)
    }
}

private struct MenuBarContents: View {
    @EnvironmentObject private var coordinator: DockPriorityCoordinator
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        Text(coordinator.protectionState.isActive ? "Protection Active" : "Protection Stopped")
            .accessibilityIdentifier("menuProtectionState")
        Text("Target: \(targetName(for: coordinator.effectiveTarget))")
            .accessibilityIdentifier("menuEffectiveTarget")
        Divider()
        Button(coordinator.protectionState.isActive ? "Stop Protection" : "Start Protection") {
            coordinator.setProtectionEnabled(!coordinator.protectionState.isActive)
        }
        .accessibilityIdentifier("menuProtectionToggle")

        Menu("Show Temporarily On") {
            if coordinator.activeDisplays.isEmpty {
                Text("No connected displays")
            } else {
                ForEach(Array(coordinator.activeDisplays.enumerated()), id: \.element.id) { index, display in
                    Button {
                        coordinator.chooseTemporaryTarget(display.identity)
                    } label: {
                        if coordinator.temporaryTarget == display.identity {
                            Label(display.name, systemImage: "checkmark")
                        } else {
                            Text(display.name)
                        }
                    }
                    .accessibilityIdentifier("menuTemporaryTarget.\(index)")
                }
            }
        }
        .accessibilityIdentifier("menuTemporaryTarget")

        if coordinator.temporaryTarget != nil {
            Button("Return to Priority") { coordinator.returnToPriority() }
                .accessibilityIdentifier("menuReturnToPriority")
        }

        Divider()
        Button("Check for Updates") { updateChecker.checkForUpdates(isManual: true) }
            .accessibilityIdentifier("menuCheckForUpdates")
        Button("Open DockPriority") { openMainWindow() }
            .accessibilityIdentifier("menuOpenMainWindow")
        Button("Quit DockPriority") {
            coordinator.stopProtection()
            NSApp.terminate(nil)
        }
    }

    private func targetName(for identity: DisplayIdentity?) -> String {
        guard let identity else { return "Unknown" }
        return coordinator.activeDisplays.first(where: { $0.identity == identity })?.name
            ?? coordinator.rememberedDisplays.first(where: { $0.identity == identity })?.lastKnownName
            ?? "Unknown display"
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible || $0.frame.width > 100 })?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: DockPriorityCoordinator?
    weak var appSettings: AppSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appSettings?.applyDockVisibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(appSettings?.runInBackground ?? false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stopProtection()
    }
}

#if DEBUG
private enum UITestFixture: String {
    case standard
    case permission

    static var current: UITestFixture? {
        let prefix = "--ui-test-fixture="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return UITestFixture(rawValue: String(argument.dropFirst(prefix.count)))
    }

    func makeSettingsDefaults() -> UserDefaults {
        let suiteName = "io.github.cinestill800t.DockPriority.UITests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "showStatusIcon")
        defaults.set(false, forKey: "hideFromDock")
        defaults.set(false, forKey: "runInBackground")
        return defaults
    }

    @MainActor
    func makeCoordinator() -> DockPriorityCoordinator {
        let studioIdentity = DisplayIdentity.cgUUID("ui-studio-display")
        let projectorIdentity = DisplayIdentity.cgUUID("ui-projector")
        let kvmIdentity = DisplayIdentity.cgUUID("ui-kvm-display")
        let studio = Self.snapshot(
            runtimeID: 101,
            identity: studioIdentity,
            name: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            isMain: true
        )
        let kvm = Self.snapshot(
            runtimeID: 202,
            identity: kvmIdentity,
            name: "KVM Display",
            frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080),
            isMain: false
        )
        let locator = UITestDockLocator(current: studioIdentity)
        let eventTap = UITestEventTap(permissionDenied: self == .permission)
        let store = UITestPriorityStore(state: StoredPriorityState(orderedDisplays: [
            RememberedDisplay(identity: studioIdentity, lastKnownName: "Studio Display"),
            RememberedDisplay(identity: projectorIdentity, lastKnownName: "Projector"),
            RememberedDisplay(identity: kvmIdentity, lastKnownName: "KVM Display")
        ]))
        return DockPriorityCoordinator(
            inventory: UITestDisplayInventory(displays: [studio, kvm]),
            locator: locator,
            relocator: UITestDockRelocator(locator: locator),
            store: store,
            watchdogScheduler: UITestWatchdogScheduler(),
            eventTapController: eventTap,
            dockEdgeProvider: UITestDockEdgeProvider()
        )
    }

    private static func snapshot(
        runtimeID: CGDirectDisplayID,
        identity: DisplayIdentity,
        name: String,
        frame: CGRect,
        isMain: Bool
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            runtimeID: runtimeID,
            identity: identity,
            name: name,
            frame: frame,
            isMain: isMain,
            isBuiltIn: false,
            modeSignature: DisplayModeSignature(
                pixelWidth: Int(frame.width * 2),
                pixelHeight: Int(frame.height * 2),
                logicalWidth: frame.width,
                logicalHeight: frame.height,
                refreshRate: 60,
                frame: frame,
                rotation: 0,
                isMain: isMain,
                isMirrored: false
            )
        )
    }
}

private final class UITestDisplayInventory: DisplayInventory, @unchecked Sendable {
    private let displays: [DisplaySnapshot]

    init(displays: [DisplaySnapshot]) {
        self.displays = displays
    }

    func activeDisplays() throws -> [DisplaySnapshot] { displays }
    func startObserving(_ handler: @escaping @Sendable (DisplayChangeReason) -> Void) {}
    func stopObserving() {}
}

private final class UITestDockLocator: DockLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var currentIdentity: DisplayIdentity?

    init(current: DisplayIdentity?) {
        currentIdentity = current
    }

    func dockDisplay(in displays: [DisplaySnapshot]) async throws -> DisplayIdentity? {
        lock.withLock { currentIdentity }
    }

    func move(to identity: DisplayIdentity) {
        lock.withLock { currentIdentity = identity }
    }
}

private final class UITestDockRelocator: DockRelocating, @unchecked Sendable {
    private let locator: UITestDockLocator

    init(locator: UITestDockLocator) {
        self.locator = locator
    }

    func relocate(to display: DisplaySnapshot) async throws {
        locator.move(to: display.identity)
    }
}

private final class UITestPriorityStore: DisplayPriorityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: StoredPriorityState

    init(state: StoredPriorityState) {
        self.state = state
    }

    func load() throws -> StoredPriorityState? {
        lock.withLock { state }
    }

    func save(_ state: StoredPriorityState) throws {
        lock.withLock { self.state = state }
    }
}

private final class UITestWatchdogScheduler: WatchdogScheduling, @unchecked Sendable {
    func start(interval: Duration, tick: @escaping @Sendable () -> Void) {}
    func stop() {}
}

private final class UITestEventTap: EventTapControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let permissionDenied: Bool
    private var running = false

    init(permissionDenied: Bool) {
        self.permissionDenied = permissionDenied
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    func start(
        handler: @escaping @Sendable (MouseEventSnapshot) -> MouseEventDisposition
    ) throws {
        if permissionDenied {
            throw EventTapControllerError.accessibilityPermissionDenied
        }
        lock.withLock { running = true }
    }

    func stop() {
        lock.withLock { running = false }
    }

    func setRelocationActive(_ active: Bool) {}
}

private struct UITestDockEdgeProvider: DockEdgeProviding {
    func currentDockEdge() throws -> DockEdge { .bottom }
}
#endif
