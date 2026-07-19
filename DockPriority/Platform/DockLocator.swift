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
    private let frameResolver: DockFrameResolving

    init(
        isTrusted: @escaping TrustProvider = { AXIsProcessTrusted() },
        runningApplications: @escaping RunningApplicationsProvider = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        },
        frameResolver: DockFrameResolving? = nil
    ) {
        self.isTrusted = isTrusted
        self.frameResolver = frameResolver ?? AccessibilityDockFrameResolver(
            runningApplications: runningApplications
        )
    }

    func dockDisplay(in displays: [DisplaySnapshot]) async throws -> DisplayIdentity? {
        guard isTrusted() else {
            throw DockLocationError.accessibilityPermissionDenied
        }
        let frames: [CGRect]
        do {
            frames = try frameResolver.dockFrames()
        } catch let error as DockFrameResolutionError {
            switch error {
            case .dockApplicationUnavailable:
                throw DockLocationError.dockApplicationUnavailable
            case let .dockWindowsUnavailable(code):
                throw DockLocationError.dockWindowsUnavailable(code)
            case .dockFrameUnavailable:
                throw DockLocationError.dockFrameUnavailable
            }
        }

        // The Dock sometimes exposes auxiliary windows. Choose the largest
        // window that is actually associated with an active display.
        for frame in frames {
            if let identity = DockFrameAssociation.identity(containingDockFrame: frame, in: displays) {
                return identity
            }
        }
        throw DockLocationError.dockDisplayNotFound
    }
}
