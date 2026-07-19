//
//  EventTapController.swift
//  DockPriority
//

import ApplicationServices
import CoreGraphics
import Foundation

struct MouseEventSnapshot: Equatable, Sendable {
    let location: CGPoint
    let sourceUserData: Int64
}

enum MouseEventDisposition: Equatable, Sendable {
    case passThrough
    case suppress
}

/// Immutable value captured by the event-tap closure. It intentionally holds
/// no coordinator/UI state because CGEvent callbacks do not run on MainActor.
struct DockMovementGuard: Equatable, Sendable {
    let blockedTriggerZones: [CGRect]

    init(
        targetIdentity: DisplayIdentity?,
        activeDisplays: [DisplaySnapshot],
        edge: DockEdge,
        triggerThickness: CGFloat = 10
    ) {
        let thickness = max(triggerThickness, 1)
        blockedTriggerZones = activeDisplays
            .filter { $0.identity != targetIdentity }
            .map { display in
                let frame = display.frame
                switch edge {
                case .bottom:
                    return CGRect(
                        x: frame.minX,
                        y: frame.maxY - min(thickness, frame.height),
                        width: frame.width,
                        height: min(thickness, frame.height)
                    )
                case .left:
                    return CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: min(thickness, frame.width),
                        height: frame.height
                    )
                case .right:
                    return CGRect(
                        x: frame.maxX - min(thickness, frame.width),
                        y: frame.minY,
                        width: min(thickness, frame.width),
                        height: frame.height
                    )
                }
            }
    }

    func disposition(for event: MouseEventSnapshot) -> MouseEventDisposition {
        blockedTriggerZones.contains { $0.contains(event.location) }
            ? .suppress
            : .passThrough
    }
}

enum EventTapControllerError: Error, Equatable, LocalizedError {
    case accessibilityPermissionDenied
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required to monitor mouse movement."
        case .tapCreationFailed:
            return "The mouse event tap could not be created. Remove and re-add DockPriority in Accessibility settings."
        }
    }
}

protocol EventTapControlling: AnyObject {
    var isRunning: Bool { get }
    func start(
        handler: @escaping @Sendable (MouseEventSnapshot) -> MouseEventDisposition
    ) throws
    func stop()
    func setRelocationActive(_ active: Bool)
}

/// Secondary production-only seam used to share a controller's unpredictable
/// marker with its relocator without widening `EventTapControlling` (and its
/// UI-test fakes).
protocol SyntheticEventMarkerProviding: AnyObject {
    var syntheticEventMarker: Int64 { get }
}

enum EventTapEventPolicy {
    static func disposition(
        for event: MouseEventSnapshot,
        relocationActive: Bool,
        syntheticEventMarker: Int64,
        handler: (@Sendable (MouseEventSnapshot) -> MouseEventDisposition)?
    ) -> MouseEventDisposition {
        if relocationActive {
            return event.sourceUserData == syntheticEventMarker ? .passThrough : .suppress
        }
        return handler?(event) ?? .passThrough
    }
}

final class CGEventTapController: EventTapControlling, SyntheticEventMarkerProviding, @unchecked Sendable {
    let syntheticEventMarker: Int64

    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var decisionHandler: (@Sendable (MouseEventSnapshot) -> MouseEventDisposition)?
    private var relocationActive = false

    init(syntheticEventMarker: Int64 = Int64.random(in: 1...Int64.max)) {
        precondition(syntheticEventMarker != 0, "Synthetic event markers must be nonzero")
        self.syntheticEventMarker = syntheticEventMarker
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return eventTap.map(CFMachPortIsValid) ?? false
    }

    deinit {
        stop()
    }

    func start(
        handler: @escaping @Sendable (MouseEventSnapshot) -> MouseEventDisposition
    ) throws {
        if isRunning {
            stateLock.lock()
            decisionHandler = handler
            stateLock.unlock()
            return
        }
        guard AXIsProcessTrusted() else {
            throw EventTapControllerError.accessibilityPermissionDenied
        }

        var creationError: Error?
        performOnMain { [self] in
            let mask = Self.mask(for: .mouseMoved)
                | Self.mask(for: .tapDisabledByTimeout)
                | Self.mask(for: .tapDisabledByUserInput)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let controller = Unmanaged<CGEventTapController>
                        .fromOpaque(userInfo)
                        .takeUnretainedValue()
                    return controller.handle(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                creationError = EventTapControllerError.tapCreationFailed
                return
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                creationError = EventTapControllerError.tapCreationFailed
                return
            }

            self.stateLock.lock()
            self.eventTap = tap
            self.runLoopSource = source
            self.decisionHandler = handler
            self.stateLock.unlock()

            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if let creationError { throw creationError }
    }

    func stop() {
        performOnMain { [self] in
            self.stateLock.lock()
            let tap = self.eventTap
            let source = self.runLoopSource
            self.eventTap = nil
            self.runLoopSource = nil
            self.decisionHandler = nil
            self.relocationActive = false
            self.stateLock.unlock()

            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
    }

    func setRelocationActive(_ active: Bool) {
        stateLock.lock()
        relocationActive = active
        stateLock.unlock()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let tap = eventTap
            stateLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }

        let sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        stateLock.lock()
        let isRelocating = relocationActive
        let handler = decisionHandler
        stateLock.unlock()

        let snapshot = MouseEventSnapshot(
            location: event.location,
            sourceUserData: sourceUserData
        )
        let disposition = EventTapEventPolicy.disposition(
            for: snapshot,
            relocationActive: isRelocating,
            syntheticEventMarker: syntheticEventMarker,
            handler: handler
        )
        return disposition == .suppress ? nil : Unmanaged.passUnretained(event)
    }

    private static func mask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << CGEventMask(type.rawValue)
    }

    private func performOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.sync(execute: action)
        }
    }
}
