import CoreGraphics
import Foundation
import Testing
@testable import DockPriority

struct DockRelocatorTests {
    private let frame = CGRect(x: 1920, y: -200, width: 2560, height: 1440)

    @Test func dockListFallbackFrameDerivesBottomEdge() throws {
        let edgeProvider = AccessibilityDockEdgeProvider(
            isTrusted: { true },
            frameResolver: FallbackFrameResolver()
        )

        #expect(try edgeProvider.currentDockEdge() == .bottom)
    }

    @Test func bottomGeometryTargetsTheRequestedDisplayCoordinates() {
        let configuration = DockRelocationConfiguration(
            horizontalAnchor: .right,
            horizontalOffset: 100,
            approachDistance: 50,
            movementStepCount: 8,
            holdEventCount: 8
        )

        let trigger = DockRelocationGeometry.triggerPoint(
            in: frame,
            edge: .bottom,
            configuration: configuration
        )
        let approach = DockRelocationGeometry.approachPoint(
            in: frame,
            edge: .bottom,
            configuration: configuration
        )

        #expect(trigger == CGPoint(x: frame.maxX - 100, y: frame.maxY - 1))
        #expect(approach == CGPoint(x: trigger.x, y: frame.maxY - 50))
        #expect(frame.contains(trigger))
        #expect(frame.contains(approach))
    }

    @Test func leftAndRightGeometryRemainInsideTheTargetBounds() {
        let configuration = DockRelocationConfiguration()

        let left = DockRelocationGeometry.triggerPoint(
            in: frame,
            edge: .left,
            configuration: configuration
        )
        let right = DockRelocationGeometry.triggerPoint(
            in: frame,
            edge: .right,
            configuration: configuration
        )

        #expect(left == CGPoint(x: frame.minX + 1, y: frame.midY))
        #expect(right == CGPoint(x: frame.maxX - 1, y: frame.midY))
        #expect(frame.contains(left))
        #expect(frame.contains(right))
    }

    @Test func infersDockOrientationFromPublicAXFrameGeometry() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]

        #expect(DockRelocationGeometry.edge(
            for: CGRect(x: 2600, y: 1360, width: 900, height: 80),
            displayFrames: displays
        ) == .bottom)
        #expect(DockRelocationGeometry.edge(
            for: CGRect(x: 1920, y: 300, width: 80, height: 800),
            displayFrames: displays
        ) == .left)
        #expect(DockRelocationGeometry.edge(
            for: CGRect(x: 4400, y: 300, width: 80, height: 800),
            displayFrames: displays
        ) == .right)
    }

    @Test func movementGuardBlocksOnlyNonTargetDockEdges() {
        let target = snapshot(
            identity: .cgUUID("target"),
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let fallback = snapshot(
            identity: .cgUUID("fallback"),
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        )
        let guardValue = DockMovementGuard(
            targetIdentity: target.identity,
            activeDisplays: [target, fallback],
            edge: .bottom
        )

        #expect(guardValue.disposition(for: MouseEventSnapshot(
            location: CGPoint(x: 900, y: 1079),
            sourceUserData: 0
        )) == .passThrough)
        #expect(guardValue.disposition(for: MouseEventSnapshot(
            location: CGPoint(x: 3000, y: 1439),
            sourceUserData: 0
        )) == .suppress)
        #expect(guardValue.disposition(for: MouseEventSnapshot(
            location: CGPoint(x: 3000, y: 1000),
            sourceUserData: 0
        )) == .passThrough)
    }

    @Test func eventMarkersArePerControllerNonzeroAndOnlyBypassDuringRelocation() {
        let firstController = CGEventTapController()
        let secondController = CGEventTapController()
        #expect(firstController.syntheticEventMarker != 0)
        #expect(secondController.syntheticEventMarker != 0)
        #expect(firstController.syntheticEventMarker != secondController.syntheticEventMarker)

        let blockedEvent = MouseEventSnapshot(
            location: CGPoint(x: 50, y: 99),
            sourceUserData: firstController.syntheticEventMarker
        )
        let movementGuard = DockMovementGuard(
            targetIdentity: .cgUUID("target"),
            activeDisplays: [
                snapshot(
                    identity: .cgUUID("target"),
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100)
                ),
                snapshot(
                    identity: .cgUUID("other"),
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100)
                ),
            ],
            edge: .bottom
        )

        #expect(EventTapEventPolicy.disposition(
            for: blockedEvent,
            relocationActive: false,
            syntheticEventMarker: firstController.syntheticEventMarker,
            handler: { movementGuard.disposition(for: $0) }
        ) == .suppress)
        #expect(EventTapEventPolicy.disposition(
            for: blockedEvent,
            relocationActive: true,
            syntheticEventMarker: firstController.syntheticEventMarker,
            handler: { movementGuard.disposition(for: $0) }
        ) == .passThrough)
        #expect(EventTapEventPolicy.disposition(
            for: MouseEventSnapshot(location: blockedEvent.location, sourceUserData: 0),
            relocationActive: true,
            syntheticEventMarker: firstController.syntheticEventMarker,
            handler: { movementGuard.disposition(for: $0) }
        ) == .suppress)
    }

    @Test func cursorRestorationFailureIsTypedAfterSuccessfulMovement() {
        let result = DockRelocationOutcome.resolve(
            movement: .success(()),
            cursorRestoration: .failure
        )

        guard case let .failure(error) = result,
              let relocationError = error as? DockRelocationError else {
            Issue.record("Expected a typed DockRelocationError")
            return
        }
        #expect(relocationError == .cursorRestorationFailed(.failure))
    }

    @Test func cursorRestorationFailurePreservesEarlierMovementFailure() {
        let result = DockRelocationOutcome.resolve(
            movement: .failure(TestMovementError.failed),
            cursorRestoration: .invalidConnection
        )

        guard case let .failure(error) = result,
              let relocationError = error as? DockRelocationError else {
            Issue.record("Expected a typed combined DockRelocationError")
            return
        }
        #expect(relocationError == .relocationAndCursorRestorationFailed(
            relocation: "Original movement failed",
            restoration: .invalidConnection
        ))
    }

    @Test func successfulCursorRestorationDoesNotChangeMovementResult() {
        let success = DockRelocationOutcome.resolve(
            movement: .success(()),
            cursorRestoration: .success
        )
        let failure = DockRelocationOutcome.resolve(
            movement: .failure(TestMovementError.failed),
            cursorRestoration: .success
        )

        if case .failure = success {
            Issue.record("A successful move and restore should remain successful")
        }
        guard case let .failure(error) = failure else {
            Issue.record("The original movement error should be preserved")
            return
        }
        #expect(error as? TestMovementError == .failed)
    }

    private func snapshot(identity: DisplayIdentity, frame: CGRect) -> DisplaySnapshot {
        DisplaySnapshot(
            runtimeID: 1,
            identity: identity,
            name: "Test Display",
            frame: frame,
            isMain: false,
            isBuiltIn: false,
            modeSignature: DisplayModeSignature(
                pixelWidth: Int(frame.width),
                pixelHeight: Int(frame.height),
                logicalWidth: frame.width,
                logicalHeight: frame.height,
                refreshRate: 60,
                frame: frame,
                rotation: 0,
                isMain: false,
                isMirrored: false
            )
        )
    }
}

private struct FallbackFrameResolver: DockFrameResolving {
    func dockFrames() throws -> [CGRect] {
        let windows: [CGRect] = []
        let windowFrames = DockAXFrameCandidateSelection.preferredWindowFrames(windows)
        if !windowFrames.isEmpty { return windowFrames }

        let frame = DockAXFrameCandidateSelection.listFrame(
            among: [FallbackDockListNode()],
            identifier: { $0.identifier },
            role: { $0.role },
            frame: { $0.frame },
            children: { _ in [] }
        )
        guard let frame else { throw DockFrameResolutionError.dockFrameUnavailable }
        return [frame]
    }
}

private struct FallbackDockListNode {
    let identifier = 1
    let role = "AXList"
    let frame = CGRect(x: 2774, y: 1363, width: 652, height: 49)
}

private enum TestMovementError: Error, Equatable, LocalizedError {
    case failed

    var errorDescription: String? { "Original movement failed" }
}
