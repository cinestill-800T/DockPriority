//
//  SystemDisplayInventory.swift
//  DockPriority
//

import AppKit
import CoreGraphics
import Foundation
import IOKit
import OSLog

enum DisplayInventoryError: Error, Equatable, LocalizedError {
    case activeDisplayQueryFailed(CGError)

    var errorDescription: String? {
        switch self {
        case let .activeDisplayQueryFailed(error):
            return "The active display list could not be read (CoreGraphics error \(error.rawValue))."
        }
    }
}

/// Every event here invalidates a temporary target. `configurationSettled` is
/// delivered after the burst of CoreGraphics/AppKit callbacks has quiesced.
enum DisplayChangeReason: String, CaseIterable, Equatable, Sendable {
    case reconfigurationBegan
    case displayAdded
    case displayRemoved
    case displayEnabled
    case displayDisabled
    case displayMoved
    case displayModeChanged
    case desktopShapeChanged
    case mainDisplayChanged
    case mirroringChanged
    case screenParametersChanged
    case configurationSettled
    case systemSleep
    case systemWake
    case screenUnlocked

    /// Only these reasons represent a stable point at which it is useful to
    /// rebuild the inventory. CoreGraphics and AppKit configuration callbacks
    /// are deliberately held until `configurationSettled`.
    var triggersInventoryRefresh: Bool {
        switch self {
        case .configurationSettled, .systemWake, .screenUnlocked:
            return true
        case .reconfigurationBegan, .displayAdded, .displayRemoved,
             .displayEnabled, .displayDisabled, .displayMoved,
             .displayModeChanged, .desktopShapeChanged, .mainDisplayChanged,
             .mirroringChanged, .screenParametersChanged, .systemSleep:
            return false
        }
    }

    static func reasons(for flags: CGDisplayChangeSummaryFlags) -> [DisplayChangeReason] {
        var reasons: [DisplayChangeReason] = []
        if flags.contains(.beginConfigurationFlag) { reasons.append(.reconfigurationBegan) }
        if flags.contains(.addFlag) { reasons.append(.displayAdded) }
        if flags.contains(.removeFlag) { reasons.append(.displayRemoved) }
        if flags.contains(.enabledFlag) { reasons.append(.displayEnabled) }
        if flags.contains(.disabledFlag) { reasons.append(.displayDisabled) }
        if flags.contains(.movedFlag) { reasons.append(.displayMoved) }
        if flags.contains(.setModeFlag) { reasons.append(.displayModeChanged) }
        if flags.contains(.desktopShapeChangedFlag) { reasons.append(.desktopShapeChanged) }
        if flags.contains(.setMainFlag) { reasons.append(.mainDisplayChanged) }
        if flags.contains(.mirrorFlag) || flags.contains(.unMirrorFlag) {
            reasons.append(.mirroringChanged)
        }
        return reasons
    }
}

protocol DisplayInventory: AnyObject {
    func activeDisplays() throws -> [DisplaySnapshot]
    func startObserving(_ handler: @escaping @Sendable (DisplayChangeReason) -> Void)
    func stopObserving()
}

private func dockPriorityDisplayReconfigurationCallback(
    _: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let inventory = Unmanaged<SystemDisplayInventory>.fromOpaque(userInfo).takeUnretainedValue()
    inventory.receiveReconfiguration(flags: flags)
}

final class SystemDisplayInventory: DisplayInventory, @unchecked Sendable {
    private struct ScreenMetadata: Sendable {
        let name: String
        let isHDR: Bool?
    }

    private struct RawDisplay {
        let runtimeID: CGDirectDisplayID
        let candidate: DisplayIdentityCandidate
        let frame: CGRect
        let name: String
        let isMain: Bool
        let isBuiltIn: Bool
        let modeSignature: DisplayModeSignature
    }

    private struct VendorProduct: Hashable {
        let vendorID: UInt32
        let productID: UInt32
    }

    private let deliveryQueue: DispatchQueue
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let settleDelay: TimeInterval
    private let wakeDelay: TimeInterval
    private let observesCGDisplayChanges: Bool
    private let logger = Logger(
        subsystem: "io.github.cinestill800t.DockPriority",
        category: "inventory"
    )
    private let stateLock = NSLock()

    private var handler: (@Sendable (DisplayChangeReason) -> Void)?
    private var applicationNotificationTokens: [NSObjectProtocol] = []
    private var workspaceNotificationTokens: [NSObjectProtocol] = []
    private var settleWorkItem: DispatchWorkItem?
    private var wakeWorkItem: DispatchWorkItem?
    private var pendingWakeReason: DisplayChangeReason?
    private var isObserving = false

    init(
        deliveryQueue: DispatchQueue = .main,
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        settleDelay: TimeInterval = 0.75,
        wakeDelay: TimeInterval = 2,
        observesCGDisplayChanges: Bool = true
    ) {
        self.deliveryQueue = deliveryQueue
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.settleDelay = settleDelay
        self.wakeDelay = wakeDelay
        self.observesCGDisplayChanges = observesCGDisplayChanges
    }

    deinit {
        stopObserving()
    }

    func activeDisplays() throws -> [DisplaySnapshot] {
        var count: UInt32 = 0
        var queryResult = CGGetActiveDisplayList(0, nil, &count)
        guard queryResult == .success else {
            throw DisplayInventoryError.activeDisplayQueryFailed(queryResult)
        }

        guard count > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        queryResult = CGGetActiveDisplayList(count, &displayIDs, &count)
        guard queryResult == .success else {
            throw DisplayInventoryError.activeDisplayQueryFailed(queryResult)
        }

        let metadata = screenMetadata()
        let iokitSerials = uniqueIOKitSerialsByVendorProduct()
        let mainDisplayID = CGMainDisplayID()

        let rawDisplays: [RawDisplay] = displayIDs.prefix(Int(count)).compactMap { displayID in
            guard CGDisplayIsOnline(displayID) != 0,
                  CGDisplayIsActive(displayID) != 0,
                  CGDisplayIsAsleep(displayID) == 0 else {
                return nil
            }

            let frame = CGDisplayBounds(displayID)
            guard frame.width > 0, frame.height > 0 else { return nil }

            let vendorID = CGDisplayVendorNumber(displayID)
            let productID = CGDisplayModelNumber(displayID)
            let cgSerial = CGDisplaySerialNumber(displayID)
            let serialNumber: UInt32
            if cgSerial != 0 {
                serialNumber = cgSerial
            } else {
                serialNumber = iokitSerials[VendorProduct(vendorID: vendorID, productID: productID)] ?? 0
            }

            let edidKey = EDIDDisplayKey.validating(
                vendorID: vendorID,
                productID: productID,
                serialNumber: serialNumber
            )
            let uuidString = Self.cgUUIDString(for: displayID)
            let candidate = DisplayIdentityCandidate(edidKey: edidKey, cgUUID: uuidString)

            let isMain = displayID == mainDisplayID
            let screenMetadata = metadata[displayID]
            let mode = CGDisplayCopyDisplayMode(displayID)
            let modeSignature = DisplayModeSignature(
                pixelWidth: mode?.pixelWidth ?? Int(frame.width),
                pixelHeight: mode?.pixelHeight ?? Int(frame.height),
                logicalWidth: CGFloat(mode?.width ?? Int(frame.width)),
                logicalHeight: CGFloat(mode?.height ?? Int(frame.height)),
                refreshRate: mode?.refreshRate ?? 0,
                frame: frame,
                rotation: CGDisplayRotation(displayID),
                isMain: isMain,
                isMirrored: CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay,
                isHDR: screenMetadata?.isHDR
            )

            return RawDisplay(
                runtimeID: displayID,
                candidate: candidate,
                frame: frame,
                name: screenMetadata?.name ?? Self.fallbackName(for: displayID, isMain: isMain),
                isMain: isMain,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                modeSignature: modeSignature
            )
        }

        let identities = DisplayIdentityResolver.resolve(rawDisplays.map(\.candidate))
        return zip(rawDisplays, identities).compactMap { raw, identity in
            guard let identity else {
                logger.error("Skipping an active display without a stable public identity")
                return nil
            }
            return DisplaySnapshot(
                runtimeID: raw.runtimeID,
                identity: identity,
                name: raw.name,
                frame: raw.frame,
                isMain: raw.isMain,
                isBuiltIn: raw.isBuiltIn,
                modeSignature: raw.modeSignature
            )
        }
    }

    func startObserving(_ handler: @escaping @Sendable (DisplayChangeReason) -> Void) {
        stopObserving()

        stateLock.lock()
        self.handler = handler
        isObserving = true
        stateLock.unlock()

        if observesCGDisplayChanges {
            let registrationError = CGDisplayRegisterReconfigurationCallback(
                dockPriorityDisplayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            if registrationError != .success {
                logger.error("Could not register the display reconfiguration callback: \(registrationError.rawValue, privacy: .public)")
            }
        }

        let screenToken = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deliver(.screenParametersChanged)
            self?.scheduleSettledDelivery()
        }
        applicationNotificationTokens.append(screenToken)

        let sleepToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deliver(.systemSleep)
        }
        workspaceNotificationTokens.append(sleepToken)

        let wakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleWakeDelivery(.systemWake)
        }
        workspaceNotificationTokens.append(wakeToken)

        let screensWakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleWakeDelivery(.screenUnlocked)
        }
        workspaceNotificationTokens.append(screensWakeToken)

        let sessionActiveToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleWakeDelivery(.screenUnlocked)
        }
        workspaceNotificationTokens.append(sessionActiveToken)
    }

    func stopObserving() {
        stateLock.lock()
        let wasObserving = isObserving
        isObserving = false
        handler = nil
        stateLock.unlock()

        if wasObserving, observesCGDisplayChanges {
            CGDisplayRemoveReconfigurationCallback(
                dockPriorityDisplayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        applicationNotificationTokens.forEach(notificationCenter.removeObserver)
        applicationNotificationTokens.removeAll()
        workspaceNotificationTokens.forEach(workspaceNotificationCenter.removeObserver)
        workspaceNotificationTokens.removeAll()

        deliveryQueue.async { [weak self] in
            self?.settleWorkItem?.cancel()
            self?.settleWorkItem = nil
            self?.wakeWorkItem?.cancel()
            self?.wakeWorkItem = nil
            self?.pendingWakeReason = nil
        }
    }

    func receiveReconfiguration(flags: CGDisplayChangeSummaryFlags) {
        let reasons = DisplayChangeReason.reasons(for: flags)
        for reason in reasons {
            deliver(reason)
        }
        scheduleSettledDelivery()
    }

    private func deliver(_ reason: DisplayChangeReason) {
        deliveryQueue.async { [weak self] in
            self?.deliverOnDeliveryQueue(reason)
        }
    }

    private func deliverOnDeliveryQueue(_ reason: DisplayChangeReason) {
        stateLock.lock()
        let currentHandler = isObserving ? handler : nil
        stateLock.unlock()
        currentHandler?(reason)
    }

    private func scheduleSettledDelivery() {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            settleWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.deliverOnDeliveryQueue(.configurationSettled)
            }
            settleWorkItem = workItem
            deliveryQueue.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
        }
    }

    /// System wake, display wake, and session activation commonly arrive as a
    /// burst for one user-visible transition. Delay them until display state is
    /// usable and collapse the burst to one refresh. A full system wake wins as
    /// the diagnostic reason when both kinds are present.
    private func scheduleWakeDelivery(_ reason: DisplayChangeReason) {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            wakeWorkItem?.cancel()
            if pendingWakeReason == .systemWake || reason == .systemWake {
                pendingWakeReason = .systemWake
            } else {
                pendingWakeReason = .screenUnlocked
            }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let reason = pendingWakeReason else { return }
                pendingWakeReason = nil
                wakeWorkItem = nil
                deliverOnDeliveryQueue(reason)
            }
            wakeWorkItem = workItem
            deliveryQueue.asyncAfter(deadline: .now() + wakeDelay, execute: workItem)
        }
    }

    private func screenMetadata() -> [CGDirectDisplayID: ScreenMetadata] {
        let build: () -> [CGDirectDisplayID: ScreenMetadata] = {
            NSScreen.screens.reduce(into: [:]) { result, screen in
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                guard let number = screen.deviceDescription[key] as? NSNumber else { return }
                let displayID = CGDirectDisplayID(number.uint32Value)
                let hdr: Bool?
                if #available(macOS 10.15, *) {
                    hdr = screen.maximumExtendedDynamicRangeColorComponentValue > 1.0
                } else {
                    hdr = nil
                }
                result[displayID] = ScreenMetadata(name: screen.localizedName, isHDR: hdr)
            }
        }

        if Thread.isMainThread { return build() }
        return DispatchQueue.main.sync(execute: build)
    }

    private static func cgUUIDString(for displayID: CGDirectDisplayID) -> String? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, unmanagedUUID.takeRetainedValue()) as String
    }

    private static func fallbackName(for displayID: CGDirectDisplayID, isMain: Bool) -> String {
        isMain ? "Main Display" : "Display \(displayID)"
    }

    /// IOKit cannot publicly map a service to a CG display ID. It is therefore
    /// only safe as a fallback when a vendor/product pair has exactly one
    /// non-zero serial. Ambiguous pairs deliberately fall back to CG UUID.
    private func uniqueIOKitSerialsByVendorProduct() -> [VendorProduct: UInt32] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IODisplayConnect"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var serials: [VendorProduct: Set<UInt32>] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let currentService = service
            if let info = IODisplayCreateInfoDictionary(
                currentService,
                IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? [String: Any],
               let vendor = Self.uint32Value(info[kDisplayVendorID]),
               let product = Self.uint32Value(info[kDisplayProductID]),
               let serial = Self.uint32Value(info[kDisplaySerialNumber]),
               vendor != 0,
               product != 0,
               serial != 0 {
                serials[VendorProduct(vendorID: vendor, productID: product), default: []].insert(serial)
            }
            IOObjectRelease(currentService)
            service = IOIteratorNext(iterator)
        }

        return serials.reduce(into: [:]) { result, entry in
            if entry.value.count == 1, let serial = entry.value.first {
                result[entry.key] = serial
            }
        }
    }

    private static func uint32Value(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        if let integer = value as? Int, integer >= 0 { return UInt32(integer) }
        return nil
    }
}
