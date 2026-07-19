//
//  DisplayIdentity.swift
//  DockPriority
//
//  Stable display identity and priority-persistence value types.
//

import CoreGraphics
import Foundation

/// The physical portion of a display identity. A zero component is not a
/// usable EDID identity and must fall back to a CoreGraphics UUID.
struct EDIDDisplayKey: Codable, Hashable, Sendable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32

    var isValid: Bool {
        vendorID != 0 && productID != 0 && serialNumber != 0
    }

    static func validating(
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32
    ) -> EDIDDisplayKey? {
        let key = EDIDDisplayKey(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber
        )
        return key.isValid ? key : nil
    }
}

enum DisplayIdentity: Codable, Hashable, Sendable {
    case edid(EDIDDisplayKey)
    case cgUUID(String)

    var stableDescription: String {
        switch self {
        case let .edid(key):
            return "edid:\(key.vendorID):\(key.productID):\(key.serialNumber)"
        case let .cgUUID(uuid):
            return "cgUUID:\(uuid)"
        }
    }
}

/// Inputs collected by `SystemDisplayInventory` before selecting a stable
/// identity. `runtimeID` deliberately never appears in a persisted model.
struct DisplayIdentityCandidate: Equatable, Sendable {
    let edidKey: EDIDDisplayKey?
    let cgUUID: String?

    init(edidKey: EDIDDisplayKey?, cgUUID: String?) {
        self.edidKey = edidKey?.isValid == true ? edidKey : nil
        let trimmedUUID = cgUUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cgUUID = (trimmedUUID?.isEmpty == false) ? trimmedUUID : nil
    }
}

/// Resolves identities for one simultaneous inventory snapshot. If an EDID
/// key appears more than once, every display using that key falls back to its
/// CoreGraphics UUID so that identical physical-key reports cannot merge two
/// distinct attached displays.
enum DisplayIdentityResolver {
    static func resolve(_ candidates: [DisplayIdentityCandidate]) -> [DisplayIdentity?] {
        let edidCounts = candidates.reduce(into: [EDIDDisplayKey: Int]()) { counts, candidate in
            if let key = candidate.edidKey {
                counts[key, default: 0] += 1
            }
        }

        return candidates.map { candidate in
            if let key = candidate.edidKey, edidCounts[key] == 1 {
                return .edid(key)
            }
            return candidate.cgUUID.map(DisplayIdentity.cgUUID)
        }
    }
}

struct DisplayModeSignature: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let logicalWidth: CGFloat
    let logicalHeight: CGFloat
    let refreshRate: Double
    let frame: CGRect
    let rotation: Double
    let isMain: Bool
    let isMirrored: Bool
    let isHDR: Bool?

    init(
        pixelWidth: Int,
        pixelHeight: Int,
        logicalWidth: CGFloat,
        logicalHeight: CGFloat,
        refreshRate: Double,
        frame: CGRect,
        rotation: Double,
        isMain: Bool,
        isMirrored: Bool,
        isHDR: Bool? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.refreshRate = refreshRate
        self.frame = frame
        self.rotation = rotation
        self.isMain = isMain
        self.isMirrored = isMirrored
        self.isHDR = isHDR
    }
}

struct DisplaySnapshot: Identifiable, Equatable, Sendable {
    let runtimeID: CGDirectDisplayID
    let identity: DisplayIdentity
    let name: String
    let frame: CGRect
    let isMain: Bool
    let isBuiltIn: Bool
    let modeSignature: DisplayModeSignature

    var id: DisplayIdentity { identity }
}

struct RememberedDisplay: Codable, Equatable, Identifiable, Sendable {
    let identity: DisplayIdentity
    var lastKnownName: String

    var id: DisplayIdentity { identity }
}

struct StoredPriorityState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var orderedDisplays: [RememberedDisplay]

    init(
        schemaVersion: Int = StoredPriorityState.currentSchemaVersion,
        orderedDisplays: [RememberedDisplay] = []
    ) {
        self.schemaVersion = schemaVersion
        self.orderedDisplays = orderedDisplays
    }

    /// Keeps the first item for an identity and preserves the user's order.
    func normalized() -> StoredPriorityState {
        var identities = Set<DisplayIdentity>()
        let displays = orderedDisplays.filter { identities.insert($0.identity).inserted }
        return StoredPriorityState(schemaVersion: schemaVersion, orderedDisplays: displays)
    }
}
