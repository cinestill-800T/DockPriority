import Foundation
import ServiceManagement
import SwiftUI

enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum CursorXPosition: String, CaseIterable {
    case left = "Left"
    case center = "Center"
    case right = "Right"
}

/// Thread-safe configuration read by the relocation adapter. App settings are
/// MainActor-isolated, while the adapter's provider is intentionally Sendable.
final class DockRelocationSettings: @unchecked Sendable {
    static let shared = DockRelocationSettings()

    private let lock = NSLock()
    private var value = DockRelocationConfiguration()

    var configuration: DockRelocationConfiguration {
        lock.withLock { value }
    }

    func update(position: CursorXPosition, offset: Double) {
        lock.withLock {
            switch position {
            case .left: value.horizontalAnchor = .left
            case .center: value.horizontalAnchor = .center
            case .right: value.horizontalAnchor = .right
            }
            value.horizontalOffset = CGFloat(max(offset, 1))
        }
    }
}

/// Preferences that are intentionally unrelated to display-selection policy.
/// Display priority and temporary targets belong exclusively to
/// `DockPriorityCoordinator` and its store.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var startAtLogin: Bool {
        didSet {
            guard !isRevertingLoginItem else { return }
            updateLoginItem()
        }
    }
    @Published var runInBackground: Bool { didSet { defaults.set(runInBackground, forKey: Keys.runInBackground) } }
    @Published var showStatusIcon: Bool { didSet { defaults.set(showStatusIcon, forKey: Keys.showStatusIcon) } }
    @Published var hideFromDock: Bool {
        didSet {
            defaults.set(hideFromDock, forKey: Keys.hideFromDock)
            applyDockVisibility()
        }
    }
    @Published var appTheme: AppTheme { didSet { defaults.set(appTheme.rawValue, forKey: Keys.appTheme) } }
    @Published var cursorPosition: CursorXPosition {
        didSet {
            defaults.set(cursorPosition.rawValue, forKey: Keys.cursorPosition)
            updateRelocationConfiguration()
        }
    }
    @Published var cursorOffset: Double {
        didSet {
            defaults.set(cursorOffset, forKey: Keys.cursorOffset)
            updateRelocationConfiguration()
        }
    }

    private let defaults: UserDefaults
    private let sideEffectsEnabled: Bool
    private var isRevertingLoginItem = false
    private var pendingMenuBarIconUpdate: Task<Void, Never>?
    private var menuBarIconUpdateGeneration: UInt64 = 0

    private enum Keys {
        static let runInBackground = "runInBackground"
        static let showStatusIcon = "showStatusIcon"
        static let hideFromDock = "hideFromDock"
        static let appTheme = "appTheme"
        static let cursorPosition = "cursorPosition"
        static let cursorOffset = "cursorOffset"
    }

    init(defaults: UserDefaults = .standard, sideEffectsEnabled: Bool = true) {
        self.defaults = defaults
        self.sideEffectsEnabled = sideEffectsEnabled
        startAtLogin = SMAppService.mainApp.status == .enabled
        runInBackground = defaults.object(forKey: Keys.runInBackground) as? Bool ?? true
        showStatusIcon = defaults.object(forKey: Keys.showStatusIcon) as? Bool ?? true
        hideFromDock = defaults.object(forKey: Keys.hideFromDock) as? Bool ?? false
        appTheme = AppTheme(rawValue: defaults.string(forKey: Keys.appTheme) ?? "") ?? .system
        cursorPosition = CursorXPosition(rawValue: defaults.string(forKey: Keys.cursorPosition) ?? "") ?? .center
        cursorOffset = defaults.object(forKey: Keys.cursorOffset) as? Double ?? 50
        updateRelocationConfiguration()
    }

    func applyDockVisibility() {
        guard sideEffectsEnabled else { return }
        NSApp.setActivationPolicy(hideFromDock ? .accessory : .regular)
    }

    /// Handles write-back from `MenuBarExtra.isInserted` without publishing
    /// same-value scene updates back into SwiftUI's render graph.
    func requestMenuBarIconVisibility(_ isVisible: Bool) {
        pendingMenuBarIconUpdate?.cancel()
        pendingMenuBarIconUpdate = nil
        menuBarIconUpdateGeneration &+= 1
        let generation = menuBarIconUpdateGeneration

        guard showStatusIcon != isVisible else { return }

        pendingMenuBarIconUpdate = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.menuBarIconUpdateGeneration == generation {
                    self.pendingMenuBarIconUpdate = nil
                }
            }
            guard !Task.isCancelled,
                  self.menuBarIconUpdateGeneration == generation,
                  self.showStatusIcon != isVisible else { return }
            self.showStatusIcon = isVisible
        }
    }

    private func updateRelocationConfiguration() {
        DockRelocationSettings.shared.update(position: cursorPosition, offset: cursorOffset)
    }

    private func updateLoginItem() {
        guard sideEffectsEnabled else { return }
        do {
            if startAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration is optional. Re-read the actual state so the toggle
            // never claims a value that macOS rejected.
            isRevertingLoginItem = true
            startAtLogin = SMAppService.mainApp.status == .enabled
            isRevertingLoginItem = false
        }
    }
}
