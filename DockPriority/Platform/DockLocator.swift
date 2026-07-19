//
//  DockLocator.swift
//  DockPriority
//

import AppKit
import ApplicationServices
import Foundation

protocol DockLocating {
    func dockDisplay(in displays: [DisplaySnapshot]) async throws -> DisplayIdentity?
}

enum DockLocationError: Error, Equatable, LocalizedError {
    case accessibilityPermissionDenied
    case dockApplicationUnavailable
    case dockWindowsUnavailable(Int32)
    case dockFrameUnavailable
    case dockDisplayNotFound

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required to locate the Dock."
        case .dockApplicationUnavailable:
            return "The Dock process is not currently available."
        case let .dockWindowsUnavailable(code):
            return "The Dock window list could not be read (Accessibility error \(code))."
        case .dockFrameUnavailable:
            return "The Dock window frame is temporarily unavailable."
        case .dockDisplayNotFound:
            return "The Dock window is not on an active display."
        }
    }
}

enum DockFrameAssociation {
    static func identity(
        containingDockFrame dockFrame: CGRect,
        in displays: [DisplaySnapshot]
    ) -> DisplayIdentity? {
        let center = CGPoint(x: dockFrame.midX, y: dockFrame.midY)
        return displays.first { $0.frame.contains(center) }?.identity
    }
}

final class AccessibilityDockLocator: DockLocating {
    typealias TrustProvider = @Sendable () -> Bool
    typealias RunningApplicationsProvider = @Sendable () -> [NSRunningApplication]

    private let isTrusted: TrustProvider
    private let runningApplications: RunningApplicationsProvider

    init(
        isTrusted: @escaping TrustProvider = { AXIsProcessTrusted() },
        runningApplications: @escaping RunningApplicationsProvider = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        }
    ) {
        self.isTrusted = isTrusted
        self.runningApplications = runningApplications
    }

    func dockDisplay(in displays: [DisplaySnapshot]) async throws -> DisplayIdentity? {
        guard isTrusted() else {
            throw DockLocationError.accessibilityPermissionDenied
        }
        guard let dockApplication = runningApplications().first else {
            throw DockLocationError.dockApplicationUnavailable
        }

        let applicationElement = AXUIElementCreateApplication(dockApplication.processIdentifier)
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard windowsResult == .success else {
            throw DockLocationError.dockWindowsUnavailable(windowsResult.rawValue)
        }
        guard let windows = windowsValue as? [AXUIElement], !windows.isEmpty else {
            throw DockLocationError.dockFrameUnavailable
        }

        let frames = windows.compactMap(Self.frame(of:))
        guard !frames.isEmpty else {
            throw DockLocationError.dockFrameUnavailable
        }

        // The Dock sometimes exposes auxiliary windows. Choose the largest
        // window that is actually associated with an active display.
        let sortedFrames = frames.sorted { lhs, rhs in
            lhs.width * lhs.height > rhs.width * rhs.height
        }
        for frame in sortedFrames {
            if let identity = DockFrameAssociation.identity(containingDockFrame: frame, in: displays) {
                return identity
            }
        }
        throw DockLocationError.dockDisplayNotFound
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
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}
