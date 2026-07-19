import CoreGraphics
import Testing
@testable import DockPriority

struct DockLocatorTests {
    @Test func associatesDockByItsCenterPoint() {
        let left = snapshot(
            identity: .cgUUID("left"),
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let right = snapshot(
            identity: .cgUUID("right"),
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        )

        let identity = DockFrameAssociation.identity(
            containingDockFrame: CGRect(x: 2500, y: 1360, width: 800, height: 80),
            in: [left, right]
        )

        #expect(identity == .cgUUID("right"))
    }

    @Test func doesNotGuessWhenDockCenterIsOutsideAllActiveDisplays() {
        let display = snapshot(
            identity: .cgUUID("only"),
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        let identity = DockFrameAssociation.identity(
            containingDockFrame: CGRect(x: 3000, y: 1500, width: 500, height: 80),
            in: [display]
        )

        #expect(identity == nil)
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
