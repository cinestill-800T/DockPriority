import CoreGraphics
import Testing
@testable import DockPriority

struct DockLocatorTests {
    @Test func emptyWindowsFallBackToDockListFrameForDisplayAssociation() async throws {
        let dockFrame = fallbackDockListFrame()
        let external = snapshot(
            identity: .cgUUID("U2723QE"),
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        )
        let locator = AccessibilityDockLocator(
            isTrusted: { true },
            frameResolver: StubDockFrameResolver(frames: [dockFrame])
        )

        let identity = try await locator.dockDisplay(in: [
            snapshot(
                identity: .cgUUID("built-in"),
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ),
            external,
        ])

        #expect(identity == .cgUUID("U2723QE"))
    }

    @Test func emptyWindowsUseOnlyFinitePositiveDockListFrames() {
        let nodes = [
            AXNode(id: 1, role: "AXGroup", frame: nil, childIDs: [2]),
            AXNode(id: 2, role: "AXList", frame: CGRect(x: 2774, y: 1363, width: 652, height: 49), childIDs: [1]),
            AXNode(id: 3, role: "AXButton", frame: CGRect(x: 0, y: 0, width: 500, height: 500), childIDs: []),
        ]

        let frame = resolvedDockListFrame(windows: [], roots: [1, 3], nodes: nodes)

        #expect(frame == CGRect(x: 2774, y: 1363, width: 652, height: 49))
    }

    @Test func invalidOrTooDeepDockListsDoNotProduceFallbackFrames() {
        let invalidNodes = [
            AXNode(id: 1, role: "AXList", frame: CGRect(x: 0, y: 0, width: 0, height: 49), childIDs: []),
        ]
        let tooDeepNodes = [
            AXNode(id: 1, role: "AXGroup", frame: nil, childIDs: [2]),
            AXNode(id: 2, role: "AXGroup", frame: nil, childIDs: [3]),
            AXNode(id: 3, role: "AXGroup", frame: nil, childIDs: [4]),
            AXNode(id: 4, role: "AXGroup", frame: nil, childIDs: [5]),
            AXNode(id: 5, role: "AXList", frame: CGRect(x: 0, y: 0, width: 100, height: 49), childIDs: []),
        ]

        #expect(resolvedDockListFrame(windows: [], roots: [1], nodes: invalidNodes) == nil)
        #expect(resolvedDockListFrame(windows: [], roots: [1], nodes: tooDeepNodes) == nil)
    }

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

    private func fallbackDockListFrame() -> CGRect {
        let nodes = [
            AXNode(id: 1, role: "AXList", frame: CGRect(x: 2774, y: 1363, width: 652, height: 49), childIDs: []),
        ]
        guard let frame = resolvedDockListFrame(windows: [], roots: [1], nodes: nodes) else {
            Issue.record("Expected a finite Dock AXList frame")
            return .zero
        }
        return frame
    }
}

private struct StubDockFrameResolver: DockFrameResolving {
    let frames: [CGRect]

    func dockFrames() throws -> [CGRect] { frames }
}

private struct AXNode {
    let id: Int
    let role: String
    let frame: CGRect?
    let childIDs: [Int]
}

private func resolvedDockListFrame(
    windows: [CGRect],
    roots: [Int],
    nodes: [AXNode]
) -> CGRect? {
    let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let rootNodes = roots.compactMap { nodesByID[$0] }
    let windowFrames = DockAXFrameCandidateSelection.preferredWindowFrames(windows)
    if !windowFrames.isEmpty { return windowFrames[0] }

    return DockAXFrameCandidateSelection.listFrame(
        among: rootNodes,
        identifier: \.id,
        role: \.role,
        frame: \.frame,
        children: { node in node.childIDs.compactMap { nodesByID[$0] } }
    )
}
