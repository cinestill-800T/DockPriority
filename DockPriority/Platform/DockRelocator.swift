//
//  DockRelocator.swift
//  DockPriority
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

protocol DockRelocating {
    func relocate(to display: DisplaySnapshot) async throws
}

enum DockEdge: Equatable, Sendable {
    case bottom
    case left
    case right
}

enum DockHorizontalAnchor: Equatable, Sendable {
    case left
    case center
    case right
}

struct DockRelocationConfiguration: Equatable, Sendable {
    var horizontalAnchor: DockHorizontalAnchor = .center
    var horizontalOffset: CGFloat = 50
    var approachDistance: CGFloat = 50
    var movementStepCount = 8
    var holdEventCount = 8
}

enum DockRelocationError: Error, Equatable, LocalizedError {
    case accessibilityPermissionDenied
    case targetDisplayUnavailable
    case dockApplicationUnavailable
    case dockFrameUnavailable
    case cursorLocationUnavailable
    case eventSourceUnavailable
    case cursorWarpFailed(CGError)
    case cursorRestorationFailed(CGError)
    case relocationAndCursorRestorationFailed(relocation: String, restoration: CGError)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required to move the Dock."
        case .targetDisplayUnavailable:
            return "The requested display is no longer active."
        case .dockApplicationUnavailable:
            return "The Dock process is not currently available."
        case .dockFrameUnavailable:
            return "The Dock frame is temporarily unavailable."
        case .cursorLocationUnavailable:
            return "The current cursor position could not be read."
        case .eventSourceUnavailable:
            return "A synthetic mouse event source could not be created."
        case let .cursorWarpFailed(error):
            return "The cursor could not be moved (CoreGraphics error \(error.rawValue))."
        case let .cursorRestorationFailed(error):
            return "The cursor could not be restored (CoreGraphics error \(error.rawValue))."
        case let .relocationAndCursorRestorationFailed(relocation, restoration):
            return "Dock relocation failed (\(relocation)); the cursor also could not be restored (CoreGraphics error \(restoration.rawValue))."
        }
    }
}

enum DockRelocationOutcome {
    static func resolve(
        movement: Result<Void, Error>,
        cursorRestoration: CGError
    ) -> Result<Void, Error> {
        guard cursorRestoration != .success else { return movement }

        switch movement {
        case .success:
            return .failure(DockRelocationError.cursorRestorationFailed(cursorRestoration))
        case let .failure(error):
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(DockRelocationError.relocationAndCursorRestorationFailed(
                relocation: description,
                restoration: cursorRestoration
            ))
        }
    }
}

enum DockRelocationGeometry {
    static func approachPoint(
        in frame: CGRect,
        edge: DockEdge,
        configuration: DockRelocationConfiguration
    ) -> CGPoint {
        let trigger = triggerPoint(in: frame, edge: edge, configuration: configuration)
        switch edge {
        case .bottom:
            return CGPoint(x: trigger.x, y: max(frame.minY, frame.maxY - configuration.approachDistance))
        case .left:
            return CGPoint(x: min(frame.maxX, frame.minX + configuration.approachDistance), y: trigger.y)
        case .right:
            return CGPoint(x: max(frame.minX, frame.maxX - configuration.approachDistance), y: trigger.y)
        }
    }

    static func triggerPoint(
        in frame: CGRect,
        edge: DockEdge,
        configuration: DockRelocationConfiguration
    ) -> CGPoint {
        switch edge {
        case .bottom:
            let inset = min(max(configuration.horizontalOffset, 1), max(frame.width / 2, 1))
            let x: CGFloat
            switch configuration.horizontalAnchor {
            case .left: x = frame.minX + inset
            case .center: x = frame.midX
            case .right: x = frame.maxX - inset
            }
            return CGPoint(x: x, y: frame.maxY - 1)
        case .left:
            return CGPoint(x: frame.minX + 1, y: frame.midY)
        case .right:
            return CGPoint(x: frame.maxX - 1, y: frame.midY)
        }
    }

    static func edge(for dockFrame: CGRect, displayFrames: [CGRect]) -> DockEdge {
        guard dockFrame.width < dockFrame.height else { return .bottom }

        let leftDistance = displayFrames.map { abs(dockFrame.minX - $0.minX) }.min() ?? .greatestFiniteMagnitude
        let rightDistance = displayFrames.map { abs(dockFrame.maxX - $0.maxX) }.min() ?? .greatestFiniteMagnitude
        return leftDistance <= rightDistance ? .left : .right
    }
}

protocol DockEdgeProviding {
    func currentDockEdge() throws -> DockEdge
}

final class AccessibilityDockEdgeProvider: DockEdgeProviding {
    typealias TrustProvider = @Sendable () -> Bool

    private let isTrusted: TrustProvider
    private let frameResolver: DockFrameResolving

    init(
        isTrusted: @escaping TrustProvider = { AXIsProcessTrusted() },
        frameResolver: DockFrameResolving = AccessibilityDockFrameResolver()
    ) {
        self.isTrusted = isTrusted
        self.frameResolver = frameResolver
    }

    func currentDockEdge() throws -> DockEdge {
        guard isTrusted() else {
            throw DockRelocationError.accessibilityPermissionDenied
        }
        let frames: [CGRect]
        do {
            frames = try frameResolver.dockFrames()
        } catch let error as DockFrameResolutionError {
            switch error {
            case .dockApplicationUnavailable:
                throw DockRelocationError.dockApplicationUnavailable
            case .dockWindowsUnavailable, .dockFrameUnavailable:
                throw DockRelocationError.dockFrameUnavailable
            }
        }
        guard let dockFrame = frames.max(by: { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }) else {
            throw DockRelocationError.dockFrameUnavailable
        }
        return DockRelocationGeometry.edge(
            for: dockFrame,
            displayFrames: Self.activeDisplayFrames()
        )
    }

    private static func activeDisplayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else { return [] }
        return identifiers.prefix(Int(count)).map(CGDisplayBounds)
    }
}

final class CGEventDockRelocator: DockRelocating, @unchecked Sendable {
    private let eventTapController: EventTapControlling
    private let edgeProvider: DockEdgeProviding
    private let configurationProvider: @Sendable () -> DockRelocationConfiguration
    private let cursorWarper: @Sendable (CGPoint) -> CGError
    private let syntheticEventMarker: Int64
    private let workQueue = DispatchQueue(label: "io.github.cinestill800t.DockPriority.relocation", qos: .userInitiated)
    private let logger = Logger(
        subsystem: "io.github.cinestill800t.DockPriority",
        category: "relocation"
    )

    init(
        eventTapController: EventTapControlling = CGEventTapController(),
        edgeProvider: DockEdgeProviding = AccessibilityDockEdgeProvider(),
        configurationProvider: @escaping @Sendable () -> DockRelocationConfiguration = {
            DockRelocationConfiguration()
        },
        cursorWarper: @escaping @Sendable (CGPoint) -> CGError = CGWarpMouseCursorPosition
    ) {
        self.eventTapController = eventTapController
        self.edgeProvider = edgeProvider
        self.configurationProvider = configurationProvider
        self.cursorWarper = cursorWarper
        syntheticEventMarker = (eventTapController as? SyntheticEventMarkerProviding)?.syntheticEventMarker
            ?? Int64.random(in: 1...Int64.max)
    }

    func relocate(to display: DisplaySnapshot) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else {
            throw DockRelocationError.accessibilityPermissionDenied
        }
        guard CGDisplayIsOnline(display.runtimeID) != 0,
              CGDisplayIsActive(display.runtimeID) != 0,
              CGDisplayIsAsleep(display.runtimeID) == 0 else {
            throw DockRelocationError.targetDisplayUnavailable
        }

        let edge = try edgeProvider.currentDockEdge()
        let configuration = configurationProvider()
        let originalPosition = try Self.cursorLocation()
        let tapWasAlreadyRunning = eventTapController.isRunning
        if !tapWasAlreadyRunning {
            try eventTapController.start { _ in .passThrough }
        }
        eventTapController.setRelocationActive(true)
        defer {
            eventTapController.setRelocationActive(false)
            if !tapWasAlreadyRunning { eventTapController.stop() }
        }

        try await performSingleAttempt(
            display: display,
            edge: edge,
            configuration: configuration,
            originalPosition: originalPosition
        )
        try Task.checkCancellation()
    }

    private func performSingleAttempt(
        display: DisplaySnapshot,
        edge: DockEdge,
        configuration: DockRelocationConfiguration,
        originalPosition: CGPoint
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                let movementResult: Result<Void, Error>
                do {
                    guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
                        throw DockRelocationError.eventSourceUnavailable
                    }

                    let approachPoint = DockRelocationGeometry.approachPoint(
                        in: display.frame,
                        edge: edge,
                        configuration: configuration
                    )
                    let triggerPoint = DockRelocationGeometry.triggerPoint(
                        in: display.frame,
                        edge: edge,
                        configuration: configuration
                    )
                    try Self.warp(to: approachPoint, using: self.cursorWarper)
                    Thread.sleep(forTimeInterval: 0.03)

                    let stepCount = max(configuration.movementStepCount, 2)
                    for index in 0..<stepCount {
                        let progress = CGFloat(index) / CGFloat(stepCount - 1)
                        let point = CGPoint(
                            x: approachPoint.x + (triggerPoint.x - approachPoint.x) * progress,
                            y: approachPoint.y + (triggerPoint.y - approachPoint.y) * progress
                        )
                        try Self.postMouseMovement(
                            at: point,
                            source: eventSource,
                            marker: self.syntheticEventMarker,
                            cursorWarper: self.cursorWarper
                        )
                        Thread.sleep(forTimeInterval: 0.015)
                    }

                    for _ in 0..<max(configuration.holdEventCount, 1) {
                        try Self.postMouseMovement(
                            at: triggerPoint,
                            source: eventSource,
                            marker: self.syntheticEventMarker,
                            cursorWarper: self.cursorWarper
                        )
                        Thread.sleep(forTimeInterval: 0.025)
                    }
                    movementResult = .success(())
                } catch {
                    movementResult = .failure(error)
                }

                let restorationResult = self.cursorWarper(originalPosition)
                let result = DockRelocationOutcome.resolve(
                    movement: movementResult,
                    cursorRestoration: restorationResult
                )
                if restorationResult != .success {
                    self.logger.error(
                        "Cursor restoration failed after a Dock relocation attempt: \(restorationResult.rawValue, privacy: .public)"
                    )
                }
                continuation.resume(with: result)
            }
        }
    }

    private static func cursorLocation() throws -> CGPoint {
        guard let event = CGEvent(source: nil) else {
            throw DockRelocationError.cursorLocationUnavailable
        }
        return event.location
    }

    private static func postMouseMovement(
        at point: CGPoint,
        source: CGEventSource,
        marker: Int64,
        cursorWarper: @Sendable (CGPoint) -> CGError
    ) throws {
        try warp(to: point, using: cursorWarper)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw DockRelocationError.eventSourceUnavailable
        }
        event.setIntegerValueField(
            .eventSourceUserData,
            value: marker
        )
        event.post(tap: .cghidEventTap)
    }

    private static func warp(
        to point: CGPoint,
        using cursorWarper: @Sendable (CGPoint) -> CGError
    ) throws {
        let error = cursorWarper(point)
        guard error == .success else {
            throw DockRelocationError.cursorWarpFailed(error)
        }
    }
}
