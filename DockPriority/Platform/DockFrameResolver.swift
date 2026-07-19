//
//  DockFrameResolver.swift
//  DockPriority
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

protocol DockFrameResolving {
    func dockFrames() throws -> [CGRect]
}

enum DockFrameResolutionError: Error, Equatable {
    case dockApplicationUnavailable
    case dockWindowsUnavailable(Int32)
    case dockFrameUnavailable
}

enum DockAXFrameCandidateSelection {
    static let maximumTraversalDepth = 4
    static let maximumTraversalNodes = 64

    static func preferredWindowFrames(_ frames: [CGRect]) -> [CGRect] {
        frames.filter(isUsable).sorted(by: isPreferred)
    }

    static func listFrame<Node, Identifier: Hashable>(
        among rootChildren: [Node],
        identifier: (Node) -> Identifier,
        role: (Node) -> String?,
        frame: (Node) -> CGRect?,
        children: (Node) -> [Node],
        maximumDepth: Int = maximumTraversalDepth,
        maximumNodes: Int = maximumTraversalNodes
    ) -> CGRect? {
        guard maximumDepth >= 1, maximumNodes > 0 else { return nil }

        var queue = rootChildren.map { ($0, 1) }
        var nextIndex = 0
        var visited = Set<Identifier>()
        var visitedNodeCount = 0

        while nextIndex < queue.count, visitedNodeCount < maximumNodes {
            let (node, depth) = queue[nextIndex]
            nextIndex += 1

            guard visited.insert(identifier(node)).inserted else { continue }
            visitedNodeCount += 1

            if role(node) == kAXListRole as String,
               let candidateFrame = frame(node),
               isUsable(candidateFrame) {
                return candidateFrame
            }

            if depth < maximumDepth {
                queue.append(contentsOf: children(node).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    static func isUsable(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0
    }

    private static func isPreferred(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let lhsArea = lhs.width * lhs.height
        let rhsArea = rhs.width * rhs.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.width != rhs.width { return lhs.width > rhs.width }
        return lhs.height > rhs.height
    }
}

final class AccessibilityDockFrameResolver: DockFrameResolving {
    typealias RunningApplicationsProvider = @Sendable () -> [NSRunningApplication]

    private let runningApplications: RunningApplicationsProvider

    init(
        runningApplications: @escaping RunningApplicationsProvider = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        }
    ) {
        self.runningApplications = runningApplications
    }

    func dockFrames() throws -> [CGRect] {
        guard let dockApplication = runningApplications().first else {
            throw DockFrameResolutionError.dockApplicationUnavailable
        }

        let applicationElement = AXUIElementCreateApplication(dockApplication.processIdentifier)
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard windowsResult == .success else {
            throw DockFrameResolutionError.dockWindowsUnavailable(windowsResult.rawValue)
        }

        let windowFrames = DockAXFrameCandidateSelection.preferredWindowFrames(
            (windowsValue as? [AXUIElement] ?? []).compactMap(Self.frame(of:))
        )
        if !windowFrames.isEmpty {
            return windowFrames
        }

        guard let listFrame = Self.listFrame(in: applicationElement) else {
            throw DockFrameResolutionError.dockFrameUnavailable
        }
        return [listFrame]
    }

    private static func listFrame(in applicationElement: AXUIElement) -> CGRect? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let rootChildren = childrenValue as? [AXUIElement] else {
            return nil
        }

        return DockAXFrameCandidateSelection.listFrame(
            among: rootChildren,
            identifier: { ObjectIdentifier($0) },
            role: { role(of: $0) },
            frame: { frame(of: $0) },
            children: { children(of: $0) }
        )
    }

    private static func role(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success else {
            return nil
        }
        return roleValue as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success else {
            return []
        }
        return childrenValue as? [AXUIElement] ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        let frame = CGRect(origin: position, size: size)
        return DockAXFrameCandidateSelection.isUsable(frame) ? frame : nil
    }
}
